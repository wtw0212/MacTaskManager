//! Small helpers for reading IORegistry properties as Core Foundation values.

use super::ffi::*;
use core_foundation::base::{CFType, TCFType};
use core_foundation::data::CFData;
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_foundation_sys::base::kCFAllocatorDefault;
use std::ffi::CString;

pub fn property(entry: io_registry_entry_t, key: &str) -> Option<CFType> {
    let key = CFString::new(key);
    let value = unsafe {
        IORegistryEntryCreateCFProperty(entry, key.as_concrete_TypeRef(), kCFAllocatorDefault, 0)
    };
    if value.is_null() {
        None
    } else {
        Some(unsafe { CFType::wrap_under_create_rule(value) })
    }
}

pub type Dict = CFDictionary<CFString, CFType>;

pub fn dictionary(value: Option<CFType>) -> Option<Dict> {
    let value = value?;
    let is_dictionary =
        value.type_of() == unsafe { core_foundation_sys::dictionary::CFDictionaryGetTypeID() };
    is_dictionary.then(|| unsafe { Dict::wrap_under_get_rule(value.as_CFTypeRef() as _) })
}

pub fn lookup(dict: &Dict, key: &str) -> Option<CFType> {
    dict.find(CFString::new(key)).map(|value| value.clone())
}

pub fn number(value: Option<CFType>) -> Option<f64> {
    value?.downcast::<CFNumber>()?.to_f64()
}

pub fn integer(value: Option<CFType>) -> Option<i64> {
    let value = value?;
    if let Some(number) = value.downcast::<CFNumber>() {
        return number.to_i64();
    }
    // Device tree properties are raw little-endian bytes.
    let data = value.downcast::<CFData>()?;
    let bytes = data.bytes();
    if bytes.len() < 4 {
        return None;
    }
    Some(i64::from(u32::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3],
    ])))
}

/// A CFString, or a NUL-terminated CFData string as the device tree stores them.
pub fn string(value: Option<CFType>) -> Option<String> {
    let value = value?;
    if let Some(string) = value.downcast::<CFString>() {
        let text = string.to_string();
        return (!text.is_empty()).then_some(text);
    }
    let data = value.downcast::<CFData>()?;
    let bytes: Vec<u8> = data
        .bytes()
        .iter()
        .copied()
        .take_while(|&b| b != 0)
        .collect();
    let text = String::from_utf8_lossy(&bytes).trim().to_string();
    (!text.is_empty()).then_some(text)
}

/// Calls `body` for every service matching `class_name`, releasing each one afterwards.
pub fn for_each_service(class_name: &str, mut body: impl FnMut(io_registry_entry_t)) {
    let Ok(name) = CString::new(class_name) else {
        return;
    };
    let mut iterator: io_iterator_t = 0;
    let matching = unsafe { IOServiceMatching(name.as_ptr()) };
    if matching.is_null() {
        return;
    }
    if unsafe { IOServiceGetMatchingServices(MAIN_PORT, matching, &mut iterator) } != 0 {
        return;
    }
    let iterator = IoObject(iterator);
    loop {
        let entry = unsafe { IOIteratorNext(iterator.0) };
        if entry == 0 {
            break;
        }
        let entry = IoObject(entry);
        body(entry.0);
    }
}

pub fn parent(entry: io_registry_entry_t) -> Option<IoObject> {
    let mut parent: io_registry_entry_t = 0;
    let result =
        unsafe { IORegistryEntryGetParentEntry(entry, SERVICE_PLANE.as_ptr().cast(), &mut parent) };
    (result == 0 && parent != 0).then_some(IoObject(parent))
}

pub fn child(entry: io_registry_entry_t) -> Option<IoObject> {
    let mut child: io_registry_entry_t = 0;
    let result =
        unsafe { IORegistryEntryGetChildEntry(entry, SERVICE_PLANE.as_ptr().cast(), &mut child) };
    (result == 0 && child != 0).then_some(IoObject(child))
}
