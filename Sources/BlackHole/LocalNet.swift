import Foundation
import Network

/// Accept loopback, link-local, and private LAN addresses. Refuse public hosts.
enum LocalNet {
    static func allows(endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            return allows(host: host)
        default:
            return false
        }
    }

    static func allows(host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            guard let dotted = dotted(address) else { return false }
            return allowsDotted4(dotted)
        case .ipv6(let address):
            return allowsV6(octets(address))
        case .name(let name, _):
            return allows(host: name)
        @unknown default:
            return false
        }
    }

    static func allows(host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("["), let end = h.firstIndex(of: "]") {
            h = String(h[h.index(after: h.startIndex)..<end])
        }
        if let zone = h.firstIndex(of: "%") {
            h = String(h[..<zone])
        }
        if h.compare("localhost", options: .caseInsensitive) == .orderedSame { return true }
        if h.lowercased().hasSuffix(".local") { return true }
        if IPv4Address(h) != nil {
            return allowsDotted4(h)
        }
        if let v6 = IPv6Address(h) {
            return allowsV6(octets(v6))
        }
        return false
    }

    static func allowsDotted4(_ dotted: String) -> Bool {
        let parts = dotted.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0]
        let b = parts[1]
        if a == 127 || a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(Int(b)) { return true }
        return false
    }

    static func allowsV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }
        if (b[0] & 0xFE) == 0xFC { return true }
        let mapped = b.prefix(10).allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
        if mapped {
            return allowsDotted4("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
        }
        return false
    }

    static func octets(_ address: IPv6Address) -> [UInt8] {
        Array(address.rawValue.prefix(16))
    }

    private static func dotted(_ address: IPv4Address) -> String? {
        let bytes = Array(address.rawValue.prefix(4))
        guard bytes.count == 4 else { return nil }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }
}
