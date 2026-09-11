import Foundation
import Network

/// Decides whether an endpoint may carry a saved API key and the user's clipboard text, and whether
/// a redirect target is still the origin that was given them.
///
/// Application Transport Security is a platform layer this app neither configures nor controls, so
/// the rule below is the app's own contract: a request leaves the process only over HTTPS, or over
/// plain HTTP to a loopback literal. Loopback is the one case where the traffic never reaches a
/// network, which is why a local engine that cannot present a certificate stays usable. Transport
/// protects that traffic in flight and says nothing about who receives it, which is what the origin
/// rule below decides.
enum EndpointTransportPolicy {
    /// Returns whether an endpoint's transport protects the credentials and content it will carry.
    static func permitsCredentials(_ url: URL) -> Bool {
        // The raw host is deliberate. A percent-encoded host matches no literal below, so an
        // endpoint that only *decodes* to a loopback name is refused rather than trusted.
        guard let host = url.host(percentEncoded: true), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            return isLoopbackLiteral(host)
        default:
            return false
        }
    }

    /// Returns whether a URL names the same origin as the one a request was already built for.
    ///
    /// Origin is scheme, host, and effective port. A redirect that keeps all three reaches the
    /// deployment the user configured; anything else is a recipient the saved key was never given
    /// to, however well the transport to it is protected. Each part is read the way its own syntax
    /// defines it — scheme and host case-insensitively, an omitted port as the scheme's default —
    /// and a URL this cannot read an origin from matches nothing, which is the same fail-closed
    /// answer `permitsCredentials` gives an ambiguous host.
    static func isSameOrigin(_ url: URL, as other: URL) -> Bool {
        guard let target = origin(of: url) else { return false }
        return target == origin(of: other)
    }

    /// The three parts that decide whether two URLs address the same deployment.
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    /// Returns a URL's origin, or nil when it does not name one this rule can compare.
    private static func origin(of url: URL) -> Origin? {
        // The scheme's default port is resolved first because it is also the test of whether this
        // app sends over that scheme at all. Reading `url.port` first would let an unsupported
        // scheme supply its own port and pass, which is the reading the guard below refuses.
        // The raw host is deliberate here for the reason it is above: an origin decided by a
        // decoder's reading of the host would let two spellings of one string name each other.
        guard let scheme = url.scheme?.lowercased(),
              let defaultPort = defaultPort(for: scheme),
              let host = url.host(percentEncoded: true)?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        return Origin(scheme: scheme, host: host, port: url.port ?? defaultPort)
    }

    /// Returns the port a scheme reaches when a URL omits one, for the schemes this app sends over.
    ///
    /// A scheme absent here has no origin at all, whether or not its URL states a port, so a
    /// redirect to one is refused rather than compared against a port the app never authorized.
    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    /// Returns whether a host names this machine's loopback interface without a name lookup.
    ///
    /// Only `localhost`, the IPv4 `127.0.0.0/8` block, and IPv6 `::1` qualify. A private-network
    /// address, or a name that merely resolves locally, does not: the endpoint alone cannot say
    /// where that traffic ends up. Forms outside these literals — an IPv4-mapped IPv6 address, for
    /// example — are refused rather than interpreted.
    private static func isLoopbackLiteral(_ host: String) -> Bool {
        // In a host, `%` introduces either percent-encoding or an IPv6 zone identifier. Both make
        // the address depend on a second reading — a decoder's, or an interface's — and `IPv6Address`
        // silently drops a zone, so `::1%anything` would otherwise pass as the bare literal.
        guard !host.contains("%") else { return false }
        if host.lowercased() == "localhost" { return true }
        if isIPv4LoopbackLiteral(host) { return true }
        if let ipv6 = IPv6Address(host) { return ipv6.isLoopback }
        return false
    }

    /// Returns whether a host is an unambiguous dotted-decimal address in `127.0.0.0/8`.
    ///
    /// Only the four-part spelling counts. `IPv4Address` also accepts the historical `inet_aton`
    /// forms — `127.1`, `2130706433`, `0x7f000001` — whose meaning depends on which parser reads
    /// them, so the app asks for an address that it and the network stack must read the same way
    /// instead of resolving that disagreement on the user's behalf. An out-of-range component is
    /// no address at all and would be looked up as a name, so it fails here rather than later.
    private static func isIPv4LoopbackLiteral(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { component -> Int? in
            guard (1...3).contains(component.count),
                  component.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(component)
        }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 127
    }
}
