import Darwin
import Foundation

/// `stat.lan`: the Mac's LAN address hint. The Mac writes the private IPv4 addresses of its Ethernet/Wi-Fi interfaces into its own `stat`
/// (`"lan":["192.168.1.10:53124", …]`, end-to-end encrypted like every `stat`), so the phone can reach the LAN-direct server without mDNS.
/// Measured on a campus Wi-Fi: the phone's NSD sent six queries and found nothing while this Mac advertised normally.
///
/// **Foundation + Darwin only** (compiled into `LinkToMacTests`). Kotlin twin: `StatLan` / `LanHostBook` in the `selfadb` module; both run
/// `protocol-vectors/stat-lan.json` (`parse`); `pick` (what is written) is the Mac's alone. The hint is untrusted input on the phone (the
/// LAN handshake authenticates whoever answers), so parsing is strict and never fatal.
enum StatLan {
    static let maxHints = 3
    private static let maxItemChars = 21  // "255.255.255.255:65535"
    private static let minPort = 1024
    private static let maxPort = 65535

    struct Hint: Equatable {
        let host: String
        let port: Int
    }

    enum Update: Equatable {
        /// No usable `lan` (missing, or not an array): the receiver keeps what it has.
        case absent
        /// The accepted hints in order, possibly none.
        case hints([Hint])
    }

    /// What a receiver makes of a decoded stat object.
    static func parse(stat: [String: Any]) -> Update {
        guard let raw = stat["lan"] as? [Any] else { return .absent }
        var out: [Hint] = []
        for item in raw {
            if out.count >= maxHints { break }
            guard let text = item as? String, let hint = parseItem(text), !out.contains(hint) else { continue }
            out.append(hint)
        }
        return .hints(out)
    }

    /// One `"a.b.c.d:port"`, or nil: canonical form, a private IPv4, a port 1024-65535.
    static func parseItem(_ item: String) -> Hint? {
        guard item.count <= maxItemChars else { return nil }
        let halves = item.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2, isPrivateIPv4(String(halves[0])) else { return nil }
        let portText = String(halves[1])
        guard portText.count <= 5, let first = portText.first, first != "0", portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), (minPort...maxPort).contains(port) else { return nil }
        return Hint(host: String(halves[0]), port: port)
    }

    /// A canonical dotted IPv4 inside 10/8, 172.16/12 or 192.168/16.
    static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var o: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), !(p.count > 1 && p.first == "0"),
                  let n = Int(p), n <= 255 else { return false }
            o.append(n)
        }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }
}

/// One network interface as the hint logic sees it (a plain value so the selection is testable without the real machine).
struct NetInterface: Equatable {
    let name: String
    let up: Bool
    let running: Bool
    let loopback: Bool
    let ipv4: String?
}

enum LanAddressHint {
    static let maxAddresses = StatLan.maxHints

    /// The `stat.lan` array: only `en<number>` interfaces that are up and running, not loopback, with a private IPv4; ordered by interface
    /// number (`en0` first, numerically); duplicates collapse; at most three. An unusable port yields none.
    static func pick(interfaces: [NetInterface], port: Int) -> [String] {
        guard (1024...65535).contains(port) else { return [] }
        var out: [String] = []
        for i in interfaces.compactMap({ ethernetNumber($0) }).sorted(by: { $0.number < $1.number }) {
            guard out.count < maxAddresses, let ip = i.interface.ipv4, StatLan.isPrivateIPv4(ip) else { continue }
            let item = "\(ip):\(port)"
            if !out.contains(item) { out.append(item) }
        }
        return out
    }

    /// The `"lan":[…]` fragment of the stat payload, or nil when there is nothing usable to say. Every item is re-checked with the phone's own
    /// rule, so a malformed address can never reach the wire. Digits, dots and a colon only: no JSON escaping needed.
    static func statFragment(_ addresses: [String]) -> String? {
        let ok = addresses.filter { StatLan.parseItem($0) != nil }
        guard !ok.isEmpty else { return nil }
        return "\"lan\":[" + ok.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    private static func ethernetNumber(_ i: NetInterface) -> (number: Int, interface: NetInterface)? {
        guard i.up, i.running, !i.loopback, i.name.hasPrefix("en"), let n = Int(i.name.dropFirst(2)), String(n) == String(i.name.dropFirst(2)) else { return nil }
        return (n, i)
    }

    /// The machine's interfaces right now (`getifaddrs`, IPv4 only).
    static func currentInterfaces() -> [NetInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [NetInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = UnsafeRawPointer(addr).load(as: sockaddr_in.self).sin_addr
                let ip = inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil ? String(cString: buf) : nil
                let flags = Int32(ifa.ifa_flags)
                out.append(NetInterface(
                    name: String(cString: ifa.ifa_name),
                    up: flags & IFF_UP != 0,
                    running: flags & IFF_RUNNING != 0,
                    loopback: flags & IFF_LOOPBACK != 0,
                    ipv4: ip))
            }
            cursor = ifa.ifa_next
        }
        return out
    }
}
