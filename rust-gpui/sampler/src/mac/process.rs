//! Lists all processes with per-process CPU and memory from `proc_pid_rusage`. Processes owned
//! by other users (e.g. root) need privileges to read, so their CPU and memory show as unavailable.

use super::ffi::responsibility_get_pid_responsible_for_pid;
use crate::{ProcessRow, ProcessStatus};
use objc2_app_kit::{NSApplicationActivationPolicy, NSWorkspace};
use std::collections::HashMap;
use std::ffi::CStr;
use std::time::Instant;

const PROC_FLAG_DARWINBG: u32 = 0x8000;
const PROC_FLAG_EXT_DARWINBG: u32 = 0x10000;
const SSTOP: u32 = 4;

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
struct Identity {
    pid: i32,
    start: u64,
}

#[derive(Clone, Copy)]
struct Counters {
    cpu: u64,
    disk: u64,
}

pub struct ProcessSampler {
    previous: HashMap<Identity, Counters>,
    previous_time: Instant,
    names: HashMap<Identity, String>,
    user_names: HashMap<u32, String>,
    ticks_to_nanoseconds: f64,
    core_count: f64,
    pids: Vec<i32>,
}

impl ProcessSampler {
    pub fn new() -> Self {
        Self {
            previous: HashMap::new(),
            previous_time: Instant::now(),
            names: HashMap::new(),
            user_names: HashMap::new(),
            ticks_to_nanoseconds: super::ticks_to_nanoseconds(),
            core_count: std::thread::available_parallelism().map_or(1, |n| n.get()) as f64,
            pids: Vec::new(),
        }
    }

    pub fn sample(&mut self) -> Vec<ProcessRow> {
        let now = Instant::now();
        let elapsed = now.duration_since(self.previous_time).as_nanos().max(1) as f64;
        self.previous_time = now;

        let mut apps: HashMap<i32, String> = HashMap::new();
        for app in NSWorkspace::sharedWorkspace().runningApplications().iter() {
            if app.activationPolicy() == NSApplicationActivationPolicy::Regular {
                let name = app
                    .localizedName()
                    .map(|n| n.to_string())
                    .unwrap_or_default();
                apps.insert(app.processIdentifier(), name);
            }
        }

        self.list_pids();
        let mut rows = Vec::with_capacity(self.pids.len());
        let mut current = HashMap::with_capacity(self.pids.len());
        let mut current_names = HashMap::with_capacity(self.pids.len());

        for index in 0..self.pids.len() {
            let pid = self.pids[index];
            if pid <= 0 {
                continue;
            }
            let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
            let has_info = unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTBSDINFO,
                    0,
                    (&mut info as *mut libc::proc_bsdinfo).cast(),
                    size,
                )
            } == size;

            let mut usage: libc::rusage_info_v4 = unsafe { std::mem::zeroed() };
            let readable = unsafe {
                libc::proc_pid_rusage(
                    pid,
                    libc::RUSAGE_INFO_V4,
                    (&mut usage as *mut libc::rusage_info_v4).cast(),
                )
            } == 0;

            let identity = Identity {
                pid,
                start: if readable {
                    usage.ri_proc_start_abstime
                } else {
                    0
                },
            };
            let name = self
                .names
                .get(&identity)
                .cloned()
                .unwrap_or_else(|| look_up_name(pid, &info, has_info));
            current_names.insert(identity, name.clone());

            let app_name = apps.get(&pid);
            let status = if has_info && info.pbi_status == SSTOP {
                ProcessStatus::Suspended
            } else if has_info
                && info.pbi_flags & (PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG) != 0
            {
                ProcessStatus::Efficiency
            } else {
                ProcessStatus::Running
            };
            let mut row = ProcessRow {
                pid,
                name: app_name.filter(|n| !n.is_empty()).cloned().unwrap_or(name),
                is_app: app_name.is_some(),
                cpu: -1.0,
                memory: 0,
                threads: thread_count(pid),
                disk_rate: -1.0,
                responsible_pid: unsafe { responsibility_get_pid_responsible_for_pid(pid) },
                parent_pid: if has_info { info.pbi_ppid as i32 } else { 0 },
                user: if has_info {
                    self.user_name(info.pbi_uid)
                } else {
                    String::new()
                },
                status,
            };

            if readable {
                let counters = Counters {
                    cpu: usage.ri_user_time + usage.ri_system_time,
                    disk: usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten,
                };
                current.insert(identity, counters);
                let old = self.previous.get(&identity);
                let delta = |value: fn(&Counters) -> u64| -> f64 {
                    match old {
                        Some(old) if value(&counters) >= value(old) => {
                            (value(&counters) - value(old)) as f64
                        }
                        _ => 0.0,
                    }
                };
                row.cpu =
                    (delta(|c| c.cpu) * self.ticks_to_nanoseconds / elapsed / self.core_count)
                        .min(1.0);
                row.memory = usage.ri_phys_footprint;
                row.disk_rate = delta(|c| c.disk) / (elapsed / 1e9);
            }
            rows.push(row);
        }

        self.previous = current;
        self.names = current_names;
        rows
    }

    fn list_pids(&mut self) {
        let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) }.max(0) as usize;
        self.pids.clear();
        self.pids.resize(count + 64, 0);
        let bytes = (self.pids.len() * std::mem::size_of::<i32>()) as i32;
        let found =
            unsafe { libc::proc_listallpids(self.pids.as_mut_ptr().cast(), bytes) }.max(0) as usize;
        self.pids.truncate(found.min(self.pids.len()));
    }

    fn user_name(&mut self, uid: u32) -> String {
        self.user_names
            .entry(uid)
            .or_insert_with(|| {
                let entry = unsafe { libc::getpwuid(uid) };
                if entry.is_null() {
                    uid.to_string()
                } else {
                    unsafe { CStr::from_ptr((*entry).pw_name) }
                        .to_string_lossy()
                        .into_owned()
                }
            })
            .clone()
    }
}

impl Default for ProcessSampler {
    fn default() -> Self {
        Self::new()
    }
}

fn look_up_name(pid: i32, info: &libc::proc_bsdinfo, has_info: bool) -> String {
    let mut path = vec![0u8; 4 * libc::PATH_MAX as usize];
    let length = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if length > 0 {
        let path = String::from_utf8_lossy(&path[..length as usize]).into_owned();
        if let Some(name) = path.rsplit('/').next().filter(|n| !n.is_empty()) {
            return name.to_string();
        }
    }
    if has_info {
        let name = unsafe { CStr::from_ptr(info.pbi_name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        if !name.is_empty() {
            return name;
        }
        let comm = unsafe { CStr::from_ptr(info.pbi_comm.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        if !comm.is_empty() {
            return comm;
        }
    }
    format!("PID {pid}")
}

fn thread_count(pid: i32) -> Option<i32> {
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as i32;
    let ok = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTASKINFO,
            0,
            (&mut info as *mut libc::proc_taskinfo).cast(),
            size,
        )
    } == size;
    ok.then_some(info.pti_threadnum)
}

/// SIGTERM, or SIGKILL when `force`.
pub fn terminate(pid: i32, force: bool) -> bool {
    unsafe { libc::kill(pid, if force { libc::SIGKILL } else { libc::SIGTERM }) == 0 }
}
