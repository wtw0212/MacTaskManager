//! Samples everything once per tick (1 s) and keeps the last 60 samples of each graph.
//! Port of the Swift `PerformanceMonitor`.

use sampler::*;
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::time::{Instant, SystemTime};

pub const HISTORY_LENGTH: usize = 60;

/// The last 60 samples, oldest first. Shared with graph closures without copying.
#[derive(Clone)]
pub struct History(Rc<VecDeque<f64>>);

impl History {
    pub fn new() -> Self {
        History(Rc::new(std::iter::repeat_n(0., HISTORY_LENGTH).collect()))
    }

    pub fn push(&mut self, value: f64) {
        // Graph closures from the last frame are gone by now, so this is normally in place.
        let values = Rc::make_mut(&mut self.0);
        if values.len() == HISTORY_LENGTH {
            values.pop_front();
        }
        values.push_back(value);
    }

    pub fn last(&self) -> f64 {
        self.0.back().copied().unwrap_or(0.)
    }

    pub fn max(&self) -> f64 {
        self.0.iter().copied().fold(0., f64::max)
    }

    pub fn values(&self) -> &VecDeque<f64> {
        &self.0
    }
}

impl Default for History {
    fn default() -> Self {
        Self::new()
    }
}

pub struct GpuState {
    pub reading: GpuReading,
    pub history: History,
    pub renderer_history: History,
    pub tiler_history: History,
}

pub struct DiskState {
    pub counters: DiskCounters,
    /// Share of the last interval the disk was busy, 0...1.
    pub active_time: f64,
    pub read_rate: f64,
    pub write_rate: f64,
    pub active_history: History,
    pub read_history: History,
    pub write_history: History,
}

pub struct NetworkState {
    pub counters: NetworkCounters,
    pub display_name: String,
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
    /// Bytes per second.
    pub receive_rate: f64,
    pub send_rate: f64,
    pub receive_history: History,
    pub send_history: History,
}

impl NetworkState {
    pub fn scale(&self) -> f64 {
        crate::theme::nice_scale(
            self.receive_history.max().max(self.send_history.max()),
            12_500.,
        )
    }
}

pub struct Monitor {
    pub cpu_name: String,
    pub physical_cores: Option<i32>,
    pub core_groups: Vec<CoreGroup>,
    pub core_histories: Vec<History>,
    pub total_history: History,
    pub temperature: TemperatureReading,
    pub thermal_state: ThermalState,
    pub process_count: usize,
    pub uptime: u64,

    pub memory: Option<MemoryReading>,
    pub memory_history: History,

    pub disks: Vec<DiskState>,
    pub networks: Vec<NetworkState>,
    pub gpus: Vec<GpuState>,
    pub startup_volume: Option<(u64, u64)>,

    /// Only sampled while the Processes page is open, like the Swift version.
    pub processes: Vec<ProcessRow>,
    process_sampler: Option<ProcessSampler>,

    cpu: CpuSampler,
    cores: Vec<f64>,
    temperature_sampler: TemperatureSampler,
    gpu_sampler: GpuSampler,
    disk_sampler: DiskSampler,
    interface_names: HashMap<String, String>,
    boot_time: Option<SystemTime>,
    last_tick: Instant,
    tick_count: u64,
}

impl Monitor {
    pub fn new() -> Self {
        let cpu = CpuSampler::new();
        let core_count = cpu.core_count();
        let mut monitor = Monitor {
            cpu_name: cpu_name(),
            physical_cores: physical_cores(),
            core_groups: core_groups(core_count),
            core_histories: (0..core_count).map(|_| History::new()).collect(),
            total_history: History::new(),
            temperature: TemperatureReading::default(),
            thermal_state: ThermalState::Nominal,
            process_count: 0,
            uptime: 0,
            memory: None,
            memory_history: History::new(),
            disks: Vec::new(),
            networks: Vec::new(),
            gpus: Vec::new(),
            startup_volume: None,
            processes: Vec::new(),
            process_sampler: None,
            cpu,
            cores: Vec::with_capacity(core_count),
            temperature_sampler: TemperatureSampler::new(),
            gpu_sampler: GpuSampler::new(),
            disk_sampler: DiskSampler::new(),
            interface_names: network_names(),
            boot_time: boot_time(),
            last_tick: Instant::now(),
            tick_count: 0,
        };
        monitor.tick();
        monitor
    }

    pub fn set_samples_processes(&mut self, on: bool) {
        if on == self.process_sampler.is_some() {
            return;
        }
        // Dropping the sampler frees its caches.
        self.process_sampler = on.then(ProcessSampler::new);
        self.processes = self
            .process_sampler
            .as_mut()
            .map(ProcessSampler::sample)
            .unwrap_or_default();
    }

    pub fn current_total(&self) -> f64 {
        self.total_history.last()
    }

    pub fn utilization(&self, group: &CoreGroup) -> f64 {
        let values: Vec<f64> = group
            .cores
            .iter()
            .filter_map(|&core| self.core_histories.get(core).map(History::last))
            .collect();
        if values.is_empty() {
            0.
        } else {
            values.iter().sum::<f64>() / values.len() as f64
        }
    }

    pub fn tick(&mut self) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_tick).as_secs_f64().max(0.001);
        self.last_tick = now;
        self.tick_count += 1;

        self.sample_cpu();
        self.temperature = self.temperature_sampler.sample();
        self.thermal_state = thermal_state();

        if let Some(reading) = memory() {
            self.memory_history.push(reading.used_fraction());
            self.memory = Some(reading);
        }

        self.sample_disks(elapsed);
        self.sample_networks(elapsed);
        self.sample_gpus();

        if self.tick_count % 10 == 1 {
            self.startup_volume = startup_volume();
            self.interface_names = network_names();
        }
        if let Some(sampler) = self.process_sampler.as_mut() {
            self.processes = sampler.sample();
        }

        self.process_count = process_count();
        self.uptime = self
            .boot_time
            .and_then(|boot| SystemTime::now().duration_since(boot).ok())
            .map_or(0, |d| d.as_secs());
    }

    fn sample_cpu(&mut self) {
        self.cpu.sample(&mut self.cores);
        if self.cores.is_empty() {
            return;
        }
        if self.core_histories.len() != self.cores.len() {
            self.core_histories = (0..self.cores.len()).map(|_| History::new()).collect();
        }
        for (history, value) in self.core_histories.iter_mut().zip(&self.cores) {
            history.push(*value);
        }
        self.total_history
            .push(self.cores.iter().sum::<f64>() / self.cores.len() as f64);
    }

    fn sample_disks(&mut self, elapsed: f64) {
        let mut previous: HashMap<String, DiskState> = self
            .disks
            .drain(..)
            .map(|disk| (disk.counters.bsd_name.clone(), disk))
            .collect();
        self.disks = self
            .disk_sampler
            .read()
            .into_iter()
            .map(|counters| match previous.remove(&counters.bsd_name) {
                None => DiskState {
                    counters,
                    active_time: 0.,
                    read_rate: 0.,
                    write_rate: 0.,
                    active_history: History::new(),
                    read_history: History::new(),
                    write_history: History::new(),
                },
                Some(mut state) => {
                    let old = &state.counters;
                    state.read_rate = rate(counters.bytes_read, old.bytes_read, elapsed);
                    state.write_rate = rate(counters.bytes_written, old.bytes_written, elapsed);
                    let busy = counters.busy_time.saturating_sub(old.busy_time) as f64;
                    state.active_time = (busy / (elapsed * 1e9)).min(1.);
                    state.counters = counters;
                    state.active_history.push(state.active_time);
                    state.read_history.push(state.read_rate);
                    state.write_history.push(state.write_rate);
                    state
                }
            })
            .collect();
    }

    fn sample_networks(&mut self, elapsed: f64) {
        let addresses = network_addresses();
        let mut previous: HashMap<String, NetworkState> = self
            .networks
            .drain(..)
            .map(|network| (network.counters.bsd_name.clone(), network))
            .collect();
        let mut networks: Vec<NetworkState> = network_counters()
            .into_iter()
            .filter(|c| {
                is_user_facing(&c.bsd_name)
                    && (addresses.contains_key(&c.bsd_name) || c.bytes_in + c.bytes_out > 0)
            })
            .map(|counters| {
                let mut state =
                    previous
                        .remove(&counters.bsd_name)
                        .unwrap_or_else(|| NetworkState {
                            counters: counters.clone(),
                            display_name: counters.bsd_name.clone(),
                            ipv4: None,
                            ipv6: None,
                            receive_rate: 0.,
                            send_rate: 0.,
                            receive_history: History::new(),
                            send_history: History::new(),
                        });
                state.receive_rate = rate(counters.bytes_in, state.counters.bytes_in, elapsed);
                state.send_rate = rate(counters.bytes_out, state.counters.bytes_out, elapsed);
                state.display_name = self
                    .interface_names
                    .get(&counters.bsd_name)
                    .cloned()
                    .unwrap_or_else(|| counters.bsd_name.clone());
                let address = addresses.get(&counters.bsd_name);
                state.ipv4 = address.and_then(|a| a.ipv4.clone());
                state.ipv6 = address.and_then(|a| a.ipv6.clone());
                state.counters = counters;
                state.receive_history.push(state.receive_rate);
                state.send_history.push(state.send_rate);
                state
            })
            .collect();
        networks.sort_by(|a, b| natural_cmp(&a.counters.bsd_name, &b.counters.bsd_name));
        self.networks = networks;
    }

    fn sample_gpus(&mut self) {
        let readings = self.gpu_sampler.sample();
        self.gpus.truncate(readings.len());
        for (index, reading) in readings.into_iter().enumerate() {
            if index == self.gpus.len() {
                self.gpus.push(GpuState {
                    reading: reading.clone(),
                    history: History::new(),
                    renderer_history: History::new(),
                    tiler_history: History::new(),
                });
            }
            let state = &mut self.gpus[index];
            state.history.push(reading.utilization.unwrap_or(0.));
            state.renderer_history.push(reading.renderer.unwrap_or(0.));
            state.tiler_history.push(reading.tiler.unwrap_or(0.));
            state.reading = reading;
        }
    }
}

fn rate(new: u64, old: u64, elapsed: f64) -> f64 {
    if new >= old {
        (new - old) as f64 / elapsed
    } else {
        0.
    }
}

/// Ethernet/Wi-Fi ("en") and cellular; hides loopback, AirDrop, VPN tunnels and bridges.
fn is_user_facing(name: &str) -> bool {
    name.starts_with("en") || name.starts_with("pdp_ip")
}

/// Compares "en2" < "en10" like Finder does.
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let split = |s: &str| {
        let digits = s.trim_start_matches(|c: char| !c.is_ascii_digit());
        (
            s[..s.len() - digits.len()].to_string(),
            digits.parse::<u64>().unwrap_or(0),
        )
    };
    split(a).cmp(&split(b)).then_with(|| a.cmp(b))
}
