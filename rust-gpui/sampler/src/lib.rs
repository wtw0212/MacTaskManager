//! Reads CPU, memory, GPU, disk, network, temperature and process statistics with the same
//! Apple APIs as the Swift version (see the table in the repository README), so the two apps
//! do the same work per tick and differ only in language and UI framework.
//!
//! On other platforms a stub with plausible fake numbers keeps the UI buildable for development.

#[cfg(target_os = "macos")]
mod mac;
#[cfg(target_os = "macos")]
pub use mac::*;

#[cfg(not(target_os = "macos"))]
mod stub;
#[cfg(not(target_os = "macos"))]
pub use stub::*;

/// A set of logical CPUs of the same kind, such as Apple's performance or efficiency cores.
#[derive(Clone, Debug)]
pub struct CoreGroup {
    /// The performance level; 0 is the fastest.
    pub level: usize,
    /// Apple's own name for the level from `hw.perflevelN.name`, e.g. "Performance".
    pub name: String,
    /// Logical CPU numbers, matching the order of `host_processor_info`.
    pub cores: Vec<usize>,
}

#[derive(Clone, Debug, Default)]
pub struct MemoryReading {
    pub total: u64,
    pub app: u64,
    pub wired: u64,
    pub compressed: u64,
    pub cached: u64,
    pub swap_used: u64,
    pub swap_total: u64,
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    pub pressure_level: Option<i32>,
}

impl MemoryReading {
    /// Same definition as Activity Monitor's "Memory Used".
    pub fn used(&self) -> u64 {
        self.app + self.wired + self.compressed
    }
    pub fn available(&self) -> u64 {
        self.total.saturating_sub(self.used())
    }
    pub fn used_fraction(&self) -> f64 {
        if self.total > 0 {
            self.used() as f64 / self.total as f64
        } else {
            0.0
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct GpuReading {
    pub name: String,
    /// Overall device utilization, 0...1.
    pub utilization: Option<f64>,
    /// Apple Silicon only: renderer and tiler utilization, 0...1.
    pub renderer: Option<f64>,
    pub tiler: Option<f64>,
    pub memory_in_use: Option<u64>,
    pub core_count: Option<i64>,
}

/// Cumulative counters for one physical disk.
#[derive(Clone, Debug, Default)]
pub struct DiskCounters {
    pub bsd_name: String,
    pub name: String,
    pub size: Option<u64>,
    pub is_internal: Option<bool>,
    pub bytes_read: u64,
    pub bytes_written: u64,
    /// Total time spent on reads and writes, in nanoseconds.
    pub busy_time: u64,
}

#[derive(Clone, Debug, Default)]
pub struct NetworkCounters {
    pub bsd_name: String,
    pub bytes_in: u64,
    pub bytes_out: u64,
    /// Link speed in bits per second, 0 when the driver doesn't report it.
    pub link_speed: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Addresses {
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct TemperatureReading {
    /// Hottest CPU sensor in °C (on M2 and later: hottest SoC die sensor).
    pub cpu: Option<f64>,
    /// GPU temperature in °C: SMC "Tg" sensors, else HID GPU sensors, else the SoC reading.
    pub gpu: Option<f64>,
    /// True when `gpu` is the shared SoC die reading because no GPU-only sensor exists.
    pub gpu_is_soc: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThermalState {
    Nominal,
    Fair,
    Serious,
    Critical,
    Unknown,
}

impl ThermalState {
    pub fn label(self) -> &'static str {
        match self {
            ThermalState::Nominal => "Normal",
            ThermalState::Fair => "Fair",
            ThermalState::Serious => "Serious (throttling)",
            ThermalState::Critical => "Critical",
            ThermalState::Unknown => "Unknown",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessStatus {
    Running,
    Suspended,
    Efficiency,
}

#[derive(Clone, Debug)]
pub struct ProcessRow {
    pub pid: i32,
    pub name: String,
    pub is_app: bool,
    /// Share of the whole machine (all cores), 0...1, like Windows. Negative when not readable.
    pub cpu: f64,
    /// Physical footprint in bytes (what Activity Monitor shows as Memory). 0 when not readable.
    pub memory: u64,
    pub threads: Option<i32>,
    /// Disk read + write in bytes per second. Negative when not readable.
    pub disk_rate: f64,
    /// The process macOS holds responsible for this one (the app, for helpers).
    pub responsible_pid: i32,
    pub parent_pid: i32,
    pub user: String,
    pub status: ProcessStatus,
}

/// This process's own resource use, for the benchmark overlay and log.
#[derive(Clone, Copy, Debug, Default)]
pub struct SelfUsage {
    /// Physical footprint in bytes (Activity Monitor's "Memory").
    pub footprint: u64,
    /// Resident set size in bytes.
    pub resident: u64,
    /// Peak physical footprint over the process lifetime.
    pub peak_footprint: u64,
    /// User + system CPU time in nanoseconds.
    pub cpu_time_ns: u64,
}
