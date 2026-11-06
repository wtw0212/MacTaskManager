#![allow(deprecated)] // libc marks mach_host_self/mach_task_self deprecated in favour of the mach2 crate.

mod ffi;
mod gpu;
mod io;
mod process;
mod registry;
mod temperature;

pub use gpu::GpuSampler;
pub use io::{DiskSampler, network_addresses, network_counters, network_names, startup_volume};
pub use process::{ProcessSampler, terminate};
pub use temperature::TemperatureSampler;

use crate::*;
use std::collections::BTreeMap;
use std::ffi::CString;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// MARK: - sysctl

pub fn sysctl_string(name: &str) -> Option<String> {
    let name = CString::new(name).ok()?;
    let mut size = 0usize;
    unsafe {
        if libc::sysctlbyname(
            name.as_ptr(),
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null_mut(),
            0,
        ) != 0
            || size == 0
        {
            return None;
        }
        let mut buffer = vec![0u8; size];
        if libc::sysctlbyname(
            name.as_ptr(),
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        ) != 0
        {
            return None;
        }
        let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
        Some(String::from_utf8_lossy(&buffer[..end]).into_owned())
    }
}

pub fn sysctl_i32(name: &str) -> Option<i32> {
    let name = CString::new(name).ok()?;
    let mut value: i32 = 0;
    let mut size = std::mem::size_of::<i32>();
    let ok = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut value as *mut i32).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    ok.then_some(value)
}

pub fn sysctl_u64(name: &str) -> Option<u64> {
    let name = CString::new(name).ok()?;
    let mut value: u64 = 0;
    let mut size = std::mem::size_of::<u64>();
    let ok = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut value as *mut u64).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    ok.then_some(value)
}

// MARK: - System info

pub fn cpu_name() -> String {
    sysctl_string("machdep.cpu.brand_string").unwrap_or_else(|| "CPU".into())
}

pub fn physical_cores() -> Option<i32> {
    sysctl_i32("hw.physicalcpu")
}

pub fn boot_time() -> Option<SystemTime> {
    let mut mib = [libc::CTL_KERN, libc::KERN_BOOTTIME];
    let mut time = libc::timeval {
        tv_sec: 0,
        tv_usec: 0,
    };
    let mut size = std::mem::size_of::<libc::timeval>();
    let ok = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            2,
            (&mut time as *mut libc::timeval).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;
    ok.then(|| {
        UNIX_EPOCH
            + Duration::from_secs(time.tv_sec as u64)
            + Duration::from_micros(time.tv_usec as u64)
    })
}

pub fn process_count() -> usize {
    unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) }.max(0) as usize
}

pub fn thermal_state() -> ThermalState {
    use objc2_foundation::{NSProcessInfo, NSProcessInfoThermalState};
    match NSProcessInfo::processInfo().thermalState() {
        NSProcessInfoThermalState::Nominal => ThermalState::Nominal,
        NSProcessInfoThermalState::Fair => ThermalState::Fair,
        NSProcessInfoThermalState::Serious => ThermalState::Serious,
        NSProcessInfoThermalState::Critical => ThermalState::Critical,
        _ => ThermalState::Unknown,
    }
}

/// Mach absolute time units to nanoseconds (1 on Intel, 125/3 on Apple Silicon).
pub(crate) fn ticks_to_nanoseconds() -> f64 {
    let mut info = libc::mach_timebase_info { numer: 0, denom: 0 };
    unsafe { libc::mach_timebase_info(&mut info) };
    if info.denom == 0 {
        1.0
    } else {
        info.numer as f64 / info.denom as f64
    }
}

pub fn self_usage() -> SelfUsage {
    let mut usage: libc::rusage_info_v4 = unsafe { std::mem::zeroed() };
    let ok = unsafe {
        libc::proc_pid_rusage(
            libc::getpid(),
            libc::RUSAGE_INFO_V4,
            (&mut usage as *mut libc::rusage_info_v4).cast(),
        )
    } == 0;
    if !ok {
        return SelfUsage::default();
    }
    let scale = ticks_to_nanoseconds();
    SelfUsage {
        footprint: usage.ri_phys_footprint,
        resident: usage.ri_resident_size,
        peak_footprint: usage.ri_lifetime_max_phys_footprint,
        cpu_time_ns: ((usage.ri_user_time + usage.ri_system_time) as f64 * scale) as u64,
    }
}

// MARK: - CPU

#[derive(Clone, Copy)]
struct Ticks {
    user: u32,
    system: u32,
    idle: u32,
    nice: u32,
}

/// Reads per-logical-core tick counters with `host_processor_info` and turns the difference
/// between two reads into a 0...1 utilization per core.
pub struct CpuSampler {
    previous: Vec<Ticks>,
}

impl CpuSampler {
    pub fn new() -> Self {
        Self {
            previous: read_ticks().unwrap_or_default(),
        }
    }

    pub fn core_count(&self) -> usize {
        self.previous.len()
    }

    /// Utilization of each logical core since the previous call, 0...1.
    pub fn sample(&mut self, out: &mut Vec<f64>) {
        out.clear();
        let Some(current) = read_ticks() else { return };
        if self.previous.len() == current.len() {
            out.extend(self.previous.iter().zip(&current).map(|(old, new)| {
                // Counters are 32-bit and wrap; wrapping subtraction keeps deltas right.
                let busy = new.user.wrapping_sub(old.user) as f64
                    + new.system.wrapping_sub(old.system) as f64
                    + new.nice.wrapping_sub(old.nice) as f64;
                let idle = new.idle.wrapping_sub(old.idle) as f64;
                let total = busy + idle;
                if total > 0.0 { busy / total } else { 0.0 }
            }));
        } else {
            out.resize(current.len(), 0.0);
        }
        self.previous = current;
    }
}

impl Default for CpuSampler {
    fn default() -> Self {
        Self::new()
    }
}

fn read_ticks() -> Option<Vec<Ticks>> {
    let mut cpu_count: libc::natural_t = 0;
    let mut info: libc::processor_info_array_t = std::ptr::null_mut();
    let mut info_count: libc::mach_msg_type_number_t = 0;
    let result = unsafe {
        libc::host_processor_info(
            libc::mach_host_self(),
            libc::PROCESSOR_CPU_LOAD_INFO,
            &mut cpu_count,
            &mut info,
            &mut info_count,
        )
    };
    if result != libc::KERN_SUCCESS || info.is_null() {
        return None;
    }
    let stride = libc::CPU_STATE_MAX as usize;
    let values = unsafe { std::slice::from_raw_parts(info, info_count as usize) };
    let tick = |core: usize, state: i32| {
        values
            .get(core * stride + state as usize)
            .copied()
            .unwrap_or(0) as u32
    };
    let ticks = (0..cpu_count as usize)
        .map(|core| Ticks {
            user: tick(core, libc::CPU_STATE_USER),
            system: tick(core, libc::CPU_STATE_SYSTEM),
            idle: tick(core, libc::CPU_STATE_IDLE),
            nice: tick(core, libc::CPU_STATE_NICE),
        })
        .collect();
    unsafe {
        libc::vm_deallocate(
            libc::mach_task_self(),
            info as libc::vm_address_t,
            info_count as usize * std::mem::size_of::<libc::integer_t>(),
        );
    }
    Some(ticks)
}

// MARK: - Core topology

pub fn core_groups(logical_count: usize) -> Vec<CoreGroup> {
    let level_count = sysctl_i32("hw.nperflevels").unwrap_or(1).max(0) as usize;
    let levels: Vec<(String, usize)> = (0..level_count)
        .map(|level| {
            (
                sysctl_string(&format!("hw.perflevel{level}.name"))
                    .unwrap_or_else(|| format!("Level {level}")),
                sysctl_i32(&format!("hw.perflevel{level}.logicalcpu"))
                    .unwrap_or(0)
                    .max(0) as usize,
            )
        })
        .collect();
    if levels.len() < 2 {
        return vec![CoreGroup {
            level: 0,
            name: "Logical processors".into(),
            cores: (0..logical_count).collect(),
        }];
    }
    if let Some(groups) = groups_from_device_tree(&levels, logical_count) {
        return groups;
    }
    // Fallback: Apple Silicon numbers the slower clusters first.
    let mut next = 0;
    let mut groups = Vec::new();
    for (level, (name, count)) in levels.iter().enumerate().rev() {
        let end = (next + count).min(logical_count);
        groups.push(CoreGroup {
            level,
            name: name.clone(),
            cores: (next..end).collect(),
        });
        next = end;
    }
    groups.sort_by_key(|group| group.level);
    groups
}

/// Reads `cluster-type` ("E", "P", ...) for every CPU node under IODeviceTree:/cpus,
/// then matches each cluster type to a performance level by core count.
fn groups_from_device_tree(
    levels: &[(String, usize)],
    logical_count: usize,
) -> Option<Vec<CoreGroup>> {
    use ffi::*;
    let path = CString::new("IODeviceTree:/cpus").ok()?;
    let cpus = unsafe { IORegistryEntryFromPath(MAIN_PORT, path.as_ptr()) };
    if cpus == 0 {
        return None;
    }
    let cpus = IoObject(cpus);
    let mut iterator: io_iterator_t = 0;
    if unsafe {
        IORegistryEntryGetChildIterator(cpus.0, DEVICE_TREE_PLANE.as_ptr().cast(), &mut iterator)
    } != 0
    {
        return None;
    }
    let iterator = IoObject(iterator);

    let mut clusters: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    loop {
        let entry = unsafe { IOIteratorNext(iterator.0) };
        if entry == 0 {
            break;
        }
        let entry = IoObject(entry);
        let kind = registry::string(registry::property(entry.0, "cluster-type"));
        let id = registry::integer(registry::property(entry.0, "logical-cpu-id"))
            .or_else(|| registry::integer(registry::property(entry.0, "cpu-id")));
        if let (Some(kind), Some(id)) = (kind, id)
            && (id as usize) < logical_count
        {
            clusters.entry(kind).or_default().push(id as usize);
        }
    }
    if clusters.values().map(Vec::len).sum::<usize>() != logical_count {
        return None;
    }

    // "E" clusters belong to the slowest level.
    let rank = |kind: &str| if kind == "E" { 1 } else { 0 };
    let mut groups = Vec::new();
    for (level, (name, count)) in levels.iter().enumerate() {
        let is_last = level == levels.len() - 1;
        let mut candidates: Vec<String> = clusters.keys().cloned().collect();
        candidates.sort_by_key(|kind| rank(kind));
        let key = candidates
            .iter()
            .find(|kind| clusters[*kind].len() == *count && (is_last || kind.as_str() != "E"))
            .or(candidates.first())
            .cloned();
        let Some(key) = key else { continue };
        let Some(mut cores) = clusters.remove(&key) else {
            continue;
        };
        cores.sort_unstable();
        groups.push(CoreGroup {
            level,
            name: name.clone(),
            cores,
        });
    }
    clusters.is_empty().then_some(groups)
}

// MARK: - Memory

pub fn memory() -> Option<MemoryReading> {
    let mut stats: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    let result = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            libc::HOST_VM_INFO64,
            (&mut stats as *mut libc::vm_statistics64).cast(),
            &mut count,
        )
    };
    if result != libc::KERN_SUCCESS {
        return None;
    }
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) }.max(4096) as u64;
    let internal = stats.internal_page_count as u64;
    let purgeable = stats.purgeable_count as u64;

    let mut swap: libc::xsw_usage = unsafe { std::mem::zeroed() };
    let mut swap_size = std::mem::size_of::<libc::xsw_usage>();
    let name = CString::new("vm.swapusage").ok()?;
    let has_swap = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut swap as *mut libc::xsw_usage).cast(),
            &mut swap_size,
            std::ptr::null_mut(),
            0,
        )
    } == 0;

    Some(MemoryReading {
        total: sysctl_u64("hw.memsize").unwrap_or(0),
        app: internal.saturating_sub(purgeable) * page,
        wired: stats.wire_count as u64 * page,
        compressed: stats.compressor_page_count as u64 * page,
        cached: (stats.external_page_count as u64 + purgeable) * page,
        swap_used: if has_swap { swap.xsu_used } else { 0 },
        swap_total: if has_swap { swap.xsu_total } else { 0 },
        pressure_level: sysctl_i32("kern.memorystatus_vm_pressure_level"),
    })
}
