//! Declarations the `libc` and `core-foundation` crates don't provide.
#![allow(
    non_camel_case_types,
    non_upper_case_globals,
    clippy::upper_case_acronyms
)]

use core_foundation_sys::array::CFArrayRef;
use core_foundation_sys::base::{CFAllocatorRef, CFTypeRef};
use core_foundation_sys::dictionary::{CFDictionaryRef, CFMutableDictionaryRef};
use core_foundation_sys::string::CFStringRef;
use libc::{c_char, c_void, kern_return_t, mach_port_t};

pub type io_object_t = mach_port_t;
pub type io_iterator_t = io_object_t;
pub type io_registry_entry_t = io_object_t;
pub type io_service_t = io_object_t;
pub type io_connect_t = io_object_t;

/// `kIOMainPortDefault`: MACH_PORT_NULL selects the default main port.
pub const MAIN_PORT: mach_port_t = 0;
pub const SERVICE_PLANE: &[u8] = b"IOService\0";
pub const DEVICE_TREE_PLANE: &[u8] = b"IODeviceTree\0";

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
    pub fn IOServiceMatching(name: *const c_char) -> CFMutableDictionaryRef;
    /// Consumes one reference to `matching`.
    pub fn IOServiceGetMatchingServices(
        main_port: mach_port_t,
        matching: CFDictionaryRef,
        existing: *mut io_iterator_t,
    ) -> kern_return_t;
    /// Consumes one reference to `matching`.
    pub fn IOServiceGetMatchingService(
        main_port: mach_port_t,
        matching: CFDictionaryRef,
    ) -> io_service_t;
    pub fn IOIteratorNext(iterator: io_iterator_t) -> io_object_t;
    pub fn IOObjectRelease(object: io_object_t) -> kern_return_t;
    pub fn IORegistryEntryCreateCFProperty(
        entry: io_registry_entry_t,
        key: CFStringRef,
        allocator: CFAllocatorRef,
        options: u32,
    ) -> CFTypeRef;
    pub fn IORegistryEntryGetParentEntry(
        entry: io_registry_entry_t,
        plane: *const c_char,
        parent: *mut io_registry_entry_t,
    ) -> kern_return_t;
    pub fn IORegistryEntryGetChildEntry(
        entry: io_registry_entry_t,
        plane: *const c_char,
        child: *mut io_registry_entry_t,
    ) -> kern_return_t;
    pub fn IORegistryEntryGetChildIterator(
        entry: io_registry_entry_t,
        plane: *const c_char,
        iterator: *mut io_iterator_t,
    ) -> kern_return_t;
    pub fn IORegistryEntryFromPath(
        main_port: mach_port_t,
        path: *const c_char,
    ) -> io_registry_entry_t;
    pub fn IORegistryEntryGetRegistryEntryID(
        entry: io_registry_entry_t,
        id: *mut u64,
    ) -> kern_return_t;
    pub fn IOServiceOpen(
        service: io_service_t,
        owning_task: mach_port_t,
        kind: u32,
        connect: *mut io_connect_t,
    ) -> kern_return_t;
    pub fn IOServiceClose(connect: io_connect_t) -> kern_return_t;
    pub fn IOConnectCallStructMethod(
        connection: io_connect_t,
        selector: u32,
        input: *const c_void,
        input_size: usize,
        output: *mut c_void,
        output_size: *mut usize,
    ) -> kern_return_t;

    // Apple has no public API for chip temperatures. These IOHIDEventSystem functions are
    // exported by IOKit but are not in the public headers (same as the Swift version).
    pub fn IOHIDEventSystemClientCreate(allocator: CFAllocatorRef) -> CFTypeRef;
    pub fn IOHIDEventSystemClientSetMatching(client: CFTypeRef, matching: CFDictionaryRef) -> i32;
    pub fn IOHIDEventSystemClientCopyServices(client: CFTypeRef) -> CFArrayRef;
    pub fn IOHIDServiceClientCopyProperty(service: CFTypeRef, key: CFStringRef) -> CFTypeRef;
    pub fn IOHIDServiceClientCopyEvent(
        service: CFTypeRef,
        kind: i64,
        options: i32,
        timestamp: i64,
    ) -> CFTypeRef;
    pub fn IOHIDEventGetFloatValue(event: CFTypeRef, field: i32) -> f64;
}

#[link(name = "SystemConfiguration", kind = "framework")]
unsafe extern "C" {
    pub fn SCNetworkInterfaceCopyAll() -> CFArrayRef;
    pub fn SCNetworkInterfaceGetBSDName(interface: CFTypeRef) -> CFStringRef;
    pub fn SCNetworkInterfaceGetLocalizedDisplayName(interface: CFTypeRef) -> CFStringRef;
}

unsafe extern "C" {
    /// Exported by libSystem but not in the public headers; Activity Monitor uses it to group
    /// helper processes (for example browser renderers) under the app they belong to.
    pub fn responsibility_get_pid_responsible_for_pid(pid: libc::pid_t) -> libc::pid_t;
}

/// RAII wrapper that releases an IOKit object.
pub struct IoObject(pub io_object_t);

impl Drop for IoObject {
    fn drop(&mut self) {
        if self.0 != 0 {
            unsafe { IOObjectRelease(self.0) };
        }
    }
}
