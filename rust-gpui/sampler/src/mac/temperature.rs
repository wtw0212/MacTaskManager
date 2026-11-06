//! Chip temperatures from IOHIDEventSystem sensors, plus the SMC for GPU sensors ("Tg*").

use super::ffi::*;
use crate::TemperatureReading;
use core_foundation::array::CFArray;
use core_foundation::base::{CFType, TCFType};
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_foundation_sys::base::kCFAllocatorDefault;

const TEMPERATURE_EVENT: i64 = 15; // kIOHIDEventTypeTemperature
const TEMPERATURE_FIELD: i32 = 15 << 16;

pub struct TemperatureSampler {
    _client: Option<CFType>,
    /// Keeps the service objects alive.
    _services: Option<CFArray<CFType>>,
    sensors: Vec<(String, CFType)>,
    smc: Option<Smc>,
}

impl TemperatureSampler {
    pub fn new() -> Self {
        let mut sampler = Self {
            _client: None,
            _services: None,
            sensors: Vec::new(),
            smc: Smc::open(),
        };
        let client = unsafe { IOHIDEventSystemClientCreate(kCFAllocatorDefault) };
        if client.is_null() {
            return sampler;
        }
        let client = unsafe { CFType::wrap_under_create_rule(client) };
        // Usage page 0xff00, usage 5: Apple vendor temperature sensors.
        let matching = CFDictionary::from_CFType_pairs(&[
            (CFString::new("PrimaryUsagePage"), CFNumber::from(0xff00i32)),
            (CFString::new("PrimaryUsage"), CFNumber::from(5i32)),
        ]);
        unsafe {
            IOHIDEventSystemClientSetMatching(client.as_CFTypeRef(), matching.as_concrete_TypeRef())
        };
        let list = unsafe { IOHIDEventSystemClientCopyServices(client.as_CFTypeRef()) };
        if !list.is_null() {
            let services: CFArray<CFType> = unsafe { CFArray::wrap_under_create_rule(list) };
            let key = CFString::new("Product");
            for service in services.iter() {
                let name = unsafe {
                    IOHIDServiceClientCopyProperty(
                        service.as_CFTypeRef(),
                        key.as_concrete_TypeRef(),
                    )
                };
                if name.is_null() {
                    continue;
                }
                let name = unsafe { CFType::wrap_under_create_rule(name) };
                if let Some(name) = name.downcast::<CFString>() {
                    sampler.sensors.push((name.to_string(), service.clone()));
                }
            }
            sampler._services = Some(services);
        }
        sampler._client = Some(client);
        sampler
    }

    pub fn sample(&mut self) -> TemperatureReading {
        let mut cpu_acc: Option<f64> = None;
        let mut die: Option<f64> = None;
        let mut gpu_hid: Option<f64> = None;
        let max =
            |slot: &mut Option<f64>, value: f64| *slot = Some(slot.map_or(value, |v| v.max(value)));

        for (name, service) in &self.sensors {
            let event = unsafe {
                IOHIDServiceClientCopyEvent(service.as_CFTypeRef(), TEMPERATURE_EVENT, 0, 0)
            };
            if event.is_null() {
                continue;
            }
            let event = unsafe { CFType::wrap_under_create_rule(event) };
            let value = unsafe { IOHIDEventGetFloatValue(event.as_CFTypeRef(), TEMPERATURE_FIELD) };
            if !(value > 0.0 && value < 150.0) {
                continue;
            }
            // M1 names CPU clusters "pACC/eACC MTR Temp"; later chips report "PMU tdie" die sensors.
            if name.contains("ACC MTR") {
                max(&mut cpu_acc, value);
            } else if name.contains("tdie") {
                max(&mut die, value);
            } else if name.contains("GPU MTR") {
                max(&mut gpu_hid, value);
            }
        }

        let cpu = cpu_acc.or(die);
        let gpu = self.smc.as_ref().and_then(Smc::gpu_temperature).or(gpu_hid);
        TemperatureReading {
            cpu,
            gpu: gpu.or(cpu),
            gpu_is_soc: gpu.is_none() && cpu.is_some(),
        }
    }
}

impl Default for TemperatureSampler {
    fn default() -> Self {
        Self::new()
    }
}

// MARK: - SMC

/// Matches the C struct SMCKeyData_t used by the AppleSMC user client (80 bytes).
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct KeyData {
    key: u32,
    version: [u8; 6], // major, minor, build, reserved, release (u16)
    limit_data: LimitData,
    key_info: KeyInfo,
    result: u8,
    status: u8,
    command: u8,
    data32: u32,
    bytes: [u8; 32],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct LimitData {
    version: u16,
    length: u16,
    cpu_limit: u32,
    gpu_limit: u32,
    mem_limit: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct KeyInfo {
    data_size: u32,
    data_type: u32,
    data_attributes: u8,
}

const _: () = assert!(std::mem::size_of::<KeyData>() == 80);

const READ_KEY: u8 = 5;
const KEY_FROM_INDEX: u8 = 8;
const KEY_INFO: u8 = 9;

struct Sensor {
    key: u32,
    info: KeyInfo,
}

/// Minimal reader for the System Management Controller, used for GPU temperature. SMC keys are
/// four-character codes; key names differ between chips, so GPU sensors are found by
/// enumerating every key once.
struct Smc {
    connection: io_connect_t,
    gpu_sensors: Vec<Sensor>,
}

impl Smc {
    fn open() -> Option<Self> {
        let matching = unsafe { IOServiceMatching(c"AppleSMC".as_ptr()) };
        let service = unsafe { IOServiceGetMatchingService(MAIN_PORT, matching) };
        if service == 0 {
            return None;
        }
        let service = IoObject(service);
        let mut connection: io_connect_t = 0;
        #[allow(deprecated)]
        let task = unsafe { libc::mach_task_self() };
        if unsafe { IOServiceOpen(service.0, task, 0, &mut connection) } != 0 {
            return None;
        }
        let mut smc = Smc {
            connection,
            gpu_sensors: Vec::new(),
        };
        smc.gpu_sensors = smc.discover(*b"Tg");
        Some(smc)
    }

    /// Average of the GPU temperature sensors that report a plausible value, in °C.
    fn gpu_temperature(&self) -> Option<f64> {
        let values: Vec<f64> = self
            .gpu_sensors
            .iter()
            .filter_map(|sensor| self.read(sensor))
            .filter(|v| *v > 0.0 && *v < 150.0)
            .collect();
        (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
    }

    fn discover(&self, prefix: [u8; 2]) -> Vec<Sensor> {
        let Some(count) = self.read_raw(four_cc(b"#KEY"), None) else {
            return Vec::new();
        };
        if count.len() < 4 {
            return Vec::new();
        }
        let count = u32::from_be_bytes([count[0], count[1], count[2], count[3]]);
        let mut sensors = Vec::new();
        for index in 0..count.min(10_000) {
            let input = KeyData {
                command: KEY_FROM_INDEX,
                data32: index,
                ..Default::default()
            };
            let Some(output) = self.call(&input) else {
                continue;
            };
            let name = output.key.to_be_bytes();
            if name[..2] != prefix {
                continue;
            }
            let Some(info) = self.key_info(output.key) else {
                continue;
            };
            let kind = info.data_type.to_be_bytes();
            if &kind != b"flt " && &kind != b"sp78" {
                continue;
            }
            let sensor = Sensor {
                key: output.key,
                info,
            };
            // Keep only sensors that report a plausible temperature right now.
            if self.read(&sensor).is_some_and(|v| v > 0.0 && v < 150.0) {
                sensors.push(sensor);
            }
        }
        sensors
    }

    fn key_info(&self, key: u32) -> Option<KeyInfo> {
        let input = KeyData {
            key,
            command: KEY_INFO,
            ..Default::default()
        };
        self.call(&input).map(|output| output.key_info)
    }

    fn read(&self, sensor: &Sensor) -> Option<f64> {
        let bytes = self.read_raw(sensor.key, Some(sensor.info))?;
        match &sensor.info.data_type.to_be_bytes() {
            // Apple Silicon: little-endian 32-bit float.
            b"flt " if bytes.len() >= 4 => {
                Some(f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64)
            }
            // Intel: signed 8.8 fixed point, big-endian.
            b"sp78" if bytes.len() >= 2 => {
                Some(i16::from_be_bytes([bytes[0], bytes[1]]) as f64 / 256.0)
            }
            _ => None,
        }
    }

    fn read_raw(&self, key: u32, info: Option<KeyInfo>) -> Option<Vec<u8>> {
        let info = info.or_else(|| self.key_info(key))?;
        let mut input = KeyData {
            key,
            command: READ_KEY,
            ..Default::default()
        };
        input.key_info.data_size = info.data_size;
        let output = self.call(&input)?;
        let size = (info.data_size as usize).min(32);
        Some(output.bytes[..size].to_vec())
    }

    fn call(&self, input: &KeyData) -> Option<KeyData> {
        let mut output = KeyData::default();
        let mut output_size = std::mem::size_of::<KeyData>();
        let result = unsafe {
            IOConnectCallStructMethod(
                self.connection,
                2,
                (input as *const KeyData).cast(),
                std::mem::size_of::<KeyData>(),
                (&mut output as *mut KeyData).cast(),
                &mut output_size,
            )
        };
        (result == 0 && output.result == 0).then_some(output)
    }
}

impl Drop for Smc {
    fn drop(&mut self) {
        if self.connection != 0 {
            unsafe { IOServiceClose(self.connection) };
        }
    }
}

fn four_cc(code: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*code)
}
