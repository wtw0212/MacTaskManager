//! Disk (IOKit `IOBlockStorageDriver` "Statistics") and network (sysctl `NET_RT_IFLIST2`,
//! SystemConfiguration names, `getifaddrs`) counters.

use super::ffi::*;
use super::registry;
use crate::{Addresses, DiskCounters, NetworkCounters};
use core_foundation::array::CFArray;
use core_foundation::base::{CFType, TCFType};
use core_foundation::string::CFString;
use std::collections::HashMap;
use std::ffi::CStr;

// MARK: - Disk

#[derive(Default)]
pub struct DiskSampler {
    /// Name, size and location never change, so they are read only once per disk.
    identities: HashMap<String, (String, Option<u64>, Option<bool>)>,
}

impl DiskSampler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn read(&mut self) -> Vec<DiskCounters> {
        let mut disks = Vec::new();
        registry::for_each_service("IOBlockStorageDriver", |driver| {
            let Some(stats) = registry::dictionary(registry::property(driver, "Statistics")) else {
                return;
            };
            let Some(media) = registry::child(driver) else {
                return;
            };
            let Some(bsd_name) = registry::string(registry::property(media.0, "BSD Name")) else {
                return;
            };

            let identity = self.identities.entry(bsd_name.clone()).or_insert_with(|| {
                let mut name = bsd_name.clone();
                let mut is_internal = None;
                if let Some(device) = registry::parent(driver) {
                    let characteristics = registry::dictionary(registry::property(
                        device.0,
                        "Device Characteristics",
                    ));
                    if let Some(product) = characteristics
                        .as_ref()
                        .and_then(|c| registry::string(registry::lookup(c, "Product Name")))
                    {
                        name = product;
                    }
                    let protocol = registry::dictionary(registry::property(
                        device.0,
                        "Protocol Characteristics",
                    ));
                    if let Some(location) = protocol.as_ref().and_then(|p| {
                        registry::string(registry::lookup(p, "Physical Interconnect Location"))
                    }) {
                        is_internal = Some(location == "Internal");
                    }
                }
                let size = registry::number(registry::property(media.0, "Size")).map(|s| s as u64);
                (name, size, is_internal)
            });

            let counter =
                |key: &str| registry::number(registry::lookup(&stats, key)).unwrap_or(0.0) as u64;
            disks.push(DiskCounters {
                bsd_name: bsd_name.clone(),
                name: identity.0.clone(),
                size: identity.1,
                is_internal: identity.2,
                bytes_read: counter("Bytes (Read)"),
                bytes_written: counter("Bytes (Write)"),
                busy_time: counter("Total Time (Read)") + counter("Total Time (Write)"),
            });
        });
        disks.sort_by(|a, b| natural_cmp(&a.bsd_name, &b.bsd_name));
        disks
    }
}

/// Free and total space of the startup volume.
pub fn startup_volume() -> Option<(u64, u64)> {
    let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statfs(c"/".as_ptr(), &mut stats) } != 0 {
        return None;
    }
    let block = stats.f_bsize as u64;
    Some((stats.f_bavail * block, stats.f_blocks * block))
}

/// Compares "disk2" < "disk10" like Finder does.
pub(crate) fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let split = |s: &str| {
        let digits = s.trim_start_matches(|c: char| !c.is_ascii_digit());
        let prefix = &s[..s.len() - digits.len()];
        (
            prefix.to_string(),
            digits.parse::<u64>().unwrap_or(0),
            s.to_string(),
        )
    };
    split(a).cmp(&split(b))
}

// MARK: - Network

/// 64-bit byte counters for every interface that is up and running, via sysctl NET_RT_IFLIST2.
pub fn network_counters() -> Vec<NetworkCounters> {
    let mut mib = [libc::CTL_NET, libc::PF_ROUTE, 0, 0, libc::NET_RT_IFLIST2, 0];
    let mut length = 0usize;
    unsafe {
        if libc::sysctl(
            mib.as_mut_ptr(),
            6,
            std::ptr::null_mut(),
            &mut length,
            std::ptr::null_mut(),
            0,
        ) != 0
            || length == 0
        {
            return Vec::new();
        }
    }
    let mut buffer = vec![0u8; length];
    if unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            6,
            buffer.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    } != 0
    {
        return Vec::new();
    }

    let mut counters = Vec::new();
    let mut offset = 0usize;
    let header_size = std::mem::size_of::<libc::if_msghdr>();
    let message_size = std::mem::size_of::<libc::if_msghdr2>();
    while offset + header_size <= length {
        let header: libc::if_msghdr =
            unsafe { std::ptr::read_unaligned(buffer.as_ptr().add(offset).cast()) };
        if header.ifm_msglen == 0 {
            break;
        }
        if header.ifm_type as i32 == libc::RTM_IFINFO2 && offset + message_size <= length {
            let message: libc::if_msghdr2 =
                unsafe { std::ptr::read_unaligned(buffer.as_ptr().add(offset).cast()) };
            let running = libc::IFF_UP | libc::IFF_RUNNING;
            if message.ifm_flags & running == running {
                let mut name = [0 as libc::c_char; libc::IF_NAMESIZE + 1];
                if !unsafe { libc::if_indextoname(message.ifm_index as u32, name.as_mut_ptr()) }
                    .is_null()
                {
                    counters.push(NetworkCounters {
                        bsd_name: unsafe { CStr::from_ptr(name.as_ptr()) }
                            .to_string_lossy()
                            .into_owned(),
                        bytes_in: message.ifm_data.ifi_ibytes,
                        bytes_out: message.ifm_data.ifi_obytes,
                        link_speed: message.ifm_data.ifi_baudrate,
                    });
                }
            }
        }
        offset += header.ifm_msglen as usize;
    }
    counters
}

/// Display names such as "Wi-Fi" or "Thunderbolt Ethernet", keyed by BSD name.
pub fn network_names() -> HashMap<String, String> {
    let mut names = HashMap::new();
    let list = unsafe { SCNetworkInterfaceCopyAll() };
    if list.is_null() {
        return names;
    }
    let list: CFArray<CFType> = unsafe { CFArray::wrap_under_create_rule(list) };
    for interface in list.iter() {
        let bsd = unsafe { SCNetworkInterfaceGetBSDName(interface.as_CFTypeRef()) };
        let display =
            unsafe { SCNetworkInterfaceGetLocalizedDisplayName(interface.as_CFTypeRef()) };
        if !bsd.is_null() && !display.is_null() {
            let bsd = unsafe { CFString::wrap_under_get_rule(bsd) }.to_string();
            let display = unsafe { CFString::wrap_under_get_rule(display) }.to_string();
            names.insert(bsd, display);
        }
    }
    names
}

/// First IPv4 and IPv6 (non link-local) address of each interface.
pub fn network_addresses() -> HashMap<String, Addresses> {
    let mut result: HashMap<String, Addresses> = HashMap::new();
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut list) } != 0 || list.is_null() {
        return result;
    }
    let mut pointer = list;
    while !pointer.is_null() {
        let entry = unsafe { &*pointer };
        pointer = entry.ifa_next;
        if entry.ifa_addr.is_null() {
            continue;
        }
        let family = unsafe { (*entry.ifa_addr).sa_family } as i32;
        if family != libc::AF_INET && family != libc::AF_INET6 {
            continue;
        }
        let length = if family == libc::AF_INET {
            std::mem::size_of::<libc::sockaddr_in>()
        } else {
            std::mem::size_of::<libc::sockaddr_in6>()
        } as libc::socklen_t;
        let mut host = [0 as libc::c_char; libc::NI_MAXHOST as usize];
        let ok = unsafe {
            libc::getnameinfo(
                entry.ifa_addr,
                length,
                host.as_mut_ptr(),
                host.len() as libc::socklen_t,
                std::ptr::null_mut(),
                0,
                libc::NI_NUMERICHOST,
            )
        } == 0;
        if !ok {
            continue;
        }
        let text = unsafe { CStr::from_ptr(host.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        let name = unsafe { CStr::from_ptr(entry.ifa_name) }
            .to_string_lossy()
            .into_owned();
        let current = result.entry(name).or_default();
        if family == libc::AF_INET && current.ipv4.is_none() {
            current.ipv4 = Some(text);
        } else if family == libc::AF_INET6 && current.ipv6.is_none() && !text.starts_with("fe80") {
            current.ipv6 = Some(text);
        }
    }
    unsafe { libc::freeifaddrs(list) };
    result
}
