import Darwin
import Foundation
import SystemConfiguration

struct NetworkCounters {
    var bsdName: String
    var bytesIn: UInt64
    var bytesOut: UInt64
}

enum NetworkSampler {
    /// 64-bit byte counters for every interface that is up and running, via sysctl NET_RT_IFLIST2.
    static func read() -> [NetworkCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [] }

        var counters: [NetworkCounters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let running = message.ifm_flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if running, if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        counters.append(NetworkCounters(
                            bsdName: String(cString: name),
                            bytesIn: message.ifm_data.ifi_ibytes,
                            bytesOut: message.ifm_data.ifi_obytes
                        ))
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return counters
    }

    /// Display names such as "Wi-Fi" or "Thunderbolt Ethernet", keyed by BSD name.
    static func displayNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = display
            }
        }
        return names
    }

    /// First IPv4 and IPv6 (non link-local) address of each interface.
    static func addresses() -> [String: (ipv4: String?, ipv6: String?)] {
        var result: [String: (ipv4: String?, ipv6: String?)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let name = String(cString: entry.ifa_name)

            var current = result[name] ?? (nil, nil)
            if family == AF_INET, current.ipv4 == nil {
                current.ipv4 = text
            } else if family == AF_INET6, current.ipv6 == nil, !text.hasPrefix("fe80") {
                current.ipv6 = text
            }
            result[name] = current
        }
        return result
    }
}
