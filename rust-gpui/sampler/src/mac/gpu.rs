//! GPU statistics from every `IOAccelerator` service in the IORegistry. Apple Silicon (AGX),
//! AMD and Intel drivers publish a `PerformanceStatistics` dictionary there; the keys differ
//! slightly by vendor.

use super::ffi::*;
use super::registry::{self, Dict};
use crate::GpuReading;
use std::collections::HashMap;

#[derive(Default)]
pub struct GpuSampler {
    /// Name and core count never change, so they are read only once per GPU.
    identities: HashMap<u64, (String, Option<i64>)>,
}

impl GpuSampler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn sample(&mut self) -> Vec<GpuReading> {
        let mut readings = Vec::new();
        registry::for_each_service("IOAccelerator", |entry| {
            readings.push(self.read(entry));
        });
        readings
    }

    fn read(&mut self, entry: io_registry_entry_t) -> GpuReading {
        let mut id = 0u64;
        unsafe { IORegistryEntryGetRegistryEntryID(entry, &mut id) };
        let (name, core_count) = self
            .identities
            .entry(id)
            .or_insert_with(|| {
                (
                    name_of(entry),
                    registry::integer(registry::property(entry, "gpu-core-count")),
                )
            })
            .clone();

        let stats = registry::dictionary(registry::property(entry, "PerformanceStatistics"));
        let get = |key: &str| {
            stats
                .as_ref()
                .and_then(|stats: &Dict| registry::number(registry::lookup(stats, key)))
        };
        let percent = |key: &str| get(key).map(|value| (value / 100.0).clamp(0.0, 1.0));

        GpuReading {
            name,
            utilization: percent("Device Utilization %").or_else(|| percent("GPU Activity(%)")),
            renderer: percent("Renderer Utilization %"),
            tiler: percent("Tiler Utilization %"),
            memory_in_use: get("In use system memory")
                .or_else(|| get("vramUsedBytes"))
                .map(|v| v.max(0.0) as u64),
            core_count,
        }
    }
}

fn name_of(entry: io_registry_entry_t) -> String {
    if let Some(model) = registry::string(registry::property(entry, "model")) {
        return model;
    }
    // Discrete and Intel GPUs keep the model on the parent PCI device.
    registry::parent(entry)
        .and_then(|parent| registry::string(registry::property(parent.0, "model")))
        .unwrap_or_else(|| "GPU".into())
}
