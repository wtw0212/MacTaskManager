//! Fake readings with the same API as the macOS samplers, so the UI builds and runs anywhere.
//! Nothing here is used on macOS.

use crate::*;
use std::collections::HashMap;
use std::time::{Instant, SystemTime};

fn wave(seed: f64) -> f64 {
    let t = START.with(|start| start.elapsed().as_secs_f64());
    (0.5 + 0.4 * ((t * 0.7 + seed * 1.7).sin() * (t * 0.13 + seed).cos())).clamp(0.0, 1.0)
}

thread_local! {
    static START: Instant = Instant::now();
}

pub fn cpu_name() -> String {
    "Simulated CPU".into()
}
pub fn physical_cores() -> Option<i32> {
    Some(12)
}
pub fn boot_time() -> Option<SystemTime> {
    Some(SystemTime::now() - std::time::Duration::from_secs(3_600))
}
pub fn process_count() -> usize {
    500
}
pub fn thermal_state() -> ThermalState {
    ThermalState::Nominal
}
pub fn self_usage() -> SelfUsage {
    SelfUsage::default()
}

#[derive(Default)]
pub struct CpuSampler;
impl CpuSampler {
    pub fn new() -> Self {
        Self
    }
    pub fn core_count(&self) -> usize {
        12
    }
    pub fn sample(&mut self, out: &mut Vec<f64>) {
        out.clear();
        out.extend((0..12).map(|i| wave(i as f64) * if i < 4 { 0.3 } else { 1.0 }));
    }
}

pub fn core_groups(logical_count: usize) -> Vec<CoreGroup> {
    let split = logical_count.min(8);
    vec![
        CoreGroup {
            level: 0,
            name: "Performance".into(),
            cores: (logical_count - split..logical_count).collect(),
        },
        CoreGroup {
            level: 1,
            name: "Efficiency".into(),
            cores: (0..logical_count - split).collect(),
        },
    ]
}

pub fn memory() -> Option<MemoryReading> {
    let gb = 1u64 << 30;
    Some(MemoryReading {
        total: 32 * gb,
        app: (10.0 * gb as f64 * (0.8 + 0.2 * wave(3.0))) as u64,
        wired: 3 * gb,
        compressed: gb,
        cached: 8 * gb,
        swap_used: 0,
        swap_total: 0,
        pressure_level: Some(1),
    })
}

#[derive(Default)]
pub struct GpuSampler;
impl GpuSampler {
    pub fn new() -> Self {
        Self
    }
    pub fn sample(&mut self) -> Vec<GpuReading> {
        vec![GpuReading {
            name: "Simulated GPU".into(),
            utilization: Some(wave(5.0) * 0.5),
            renderer: Some(wave(6.0) * 0.4),
            tiler: Some(wave(7.0) * 0.3),
            memory_in_use: Some(2 << 30),
            core_count: Some(20),
        }]
    }
}

#[derive(Default)]
pub struct DiskSampler {
    total: u64,
}
impl DiskSampler {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn read(&mut self) -> Vec<DiskCounters> {
        self.total += (wave(9.0) * 30_000_000.0) as u64;
        vec![DiskCounters {
            bsd_name: "disk0".into(),
            name: "APPLE SSD".into(),
            size: Some(1 << 40),
            is_internal: Some(true),
            bytes_read: self.total,
            bytes_written: self.total / 2,
            busy_time: self.total * 3,
        }]
    }
}

pub fn startup_volume() -> Option<(u64, u64)> {
    Some((400 << 30, 1 << 40))
}

thread_local! {
    static NET: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

pub fn network_counters() -> Vec<NetworkCounters> {
    let total = NET.with(|n| {
        n.set(n.get() + (wave(11.0) * 2_000_000.0) as u64);
        n.get()
    });
    vec![NetworkCounters {
        bsd_name: "en0".into(),
        bytes_in: total,
        bytes_out: total / 4,
        link_speed: 0,
    }]
}

pub fn network_names() -> HashMap<String, String> {
    HashMap::from([("en0".to_string(), "Wi-Fi".to_string())])
}

pub fn network_addresses() -> HashMap<String, Addresses> {
    HashMap::from([(
        "en0".to_string(),
        Addresses {
            ipv4: Some("192.168.1.10".into()),
            ipv6: None,
        },
    )])
}

#[derive(Default)]
pub struct TemperatureSampler;
impl TemperatureSampler {
    pub fn new() -> Self {
        Self
    }
    pub fn sample(&mut self) -> TemperatureReading {
        TemperatureReading {
            cpu: Some(45.0 + 10.0 * wave(2.0)),
            gpu: Some(40.0),
            gpu_is_soc: false,
        }
    }
}

#[derive(Default)]
pub struct ProcessSampler;
impl ProcessSampler {
    pub fn new() -> Self {
        Self
    }
    pub fn sample(&mut self) -> Vec<ProcessRow> {
        (1..400)
            .map(|pid| ProcessRow {
                pid,
                name: if pid % 40 == 0 {
                    format!("App {pid}")
                } else {
                    format!("process{pid}")
                },
                is_app: pid % 40 == 0,
                cpu: wave(pid as f64) * 0.02,
                memory: (pid as u64 * 7_919 % 500) << 20,
                threads: Some(pid % 30 + 1),
                disk_rate: 0.0,
                responsible_pid: if pid % 40 < 3 { pid - pid % 40 } else { pid },
                parent_pid: 1,
                user: "user".into(),
                status: ProcessStatus::Running,
            })
            .collect()
    }
}

pub fn terminate(_pid: i32, _force: bool) -> bool {
    false
}
