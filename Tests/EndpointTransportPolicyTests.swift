import XCTest
@testable import ClipboardTTSApp

final class EndpointTransportPolicyTests: XCTestCase {
    func testHTTPSAnywhereAndLoopbackHTTPMayCarryCredentials() throws {
        // WHY: HTTPS protects the key wherever the endpoint lives, and a local engine has no
        // certificate to present. Refusing either would make the rule unusable rather than safe:
        // the documented local-engine setup would stop working the moment the rule shipped.
        let permitted = [
            "https://api.openai.com/v1/audio/speech",
            "https://custom.example:8443/v1/audio/speech",
            "HTTPS://custom.example/v1/audio/speech",
            "http://localhost:8080/v1/audio/speech",
            "http://LocalHost/v1/audio/speech",
            "http://127.0.0.1:8080/v1/audio/speech",
            "http://127.0.0.2/v1/audio/speech",
            "http://127.255.255.254/v1/audio/speech",
            "http://[::1]:8080/v1/audio/speech",
            "http://[0:0:0:0:0:0:0:1]/v1/audio/speech"
        ]

        for endpoint in permitted {
            let url = try XCTUnwrap(URL(string: endpoint))
            XCTAssertTrue(
                EndpointTransportPolicy.permitsCredentials(url),
                "\(endpoint) is a supported endpoint and must stay usable."
            )
        }
    }

    func testCleartextRemoteAndPrivateNetworkEndpointsAreRefused() throws {
        // WHY: These are exactly the endpoints that would put the saved key and the user's
        // clipboard text on the wire. A private-LAN address is not loopback: the app cannot tell
        // from the endpoint alone whether that traffic stays on the user's own machine.
        let refused = [
            "http://tts.example.com/v1/audio/speech",
            "http://192.168.1.10:8080/v1/audio/speech",
            "http://10.0.0.5/v1/audio/speech",
            "http://172.16.0.3/v1/audio/speech",
            "http://tts.local/v1/audio/speech"
        ]

        for endpoint in refused {
            let url = try XCTUnwrap(URL(string: endpoint))
            XCTAssertFalse(
                EndpointTransportPolicy.permitsCredentials(url),
                "\(endpoint) would send credentials over cleartext to a host the app cannot vouch for."
            )
        }
    }

    func testHostsThatOnlyResembleLoopbackAreRefused() throws {
        // WHY: The first entries reach a remote host while reading as local, so the rule must match
        // the parsed host against literals rather than search the endpoint text. The rest are
        // ambiguous spellings — `inet_aton` short, decimal, hex, octal, IPv4-mapped IPv6, and
        // zone-suffixed forms — that a permissive parser resolves to a loopback address anyway.
        // They are refused deliberately: their meaning depends on which parser reads them, and on
        // an interface in the zoned case, while the user can always write an unambiguous one.
        let refused = [
            "http://localhost.example.com/v1/audio/speech",
            "http://notlocalhost/v1/audio/speech",
            "http://127.0.0.1.example.com/v1/audio/speech",
            "http://127.0.0.1@example.com/v1/audio/speech",
            "http://%6cocalhost/v1/audio/speech",
            "http://[::1%25lo0]/v1/audio/speech",
            "http://[::1%25anything]/v1/audio/speech",
            "http://[::ffff:127.0.0.1]/v1/audio/speech",
            "http://127.1/v1/audio/speech",
            "http://127.0.1/v1/audio/speech",
            "http://2130706433/v1/audio/speech",
            "http://0x7f000001/v1/audio/speech",
            "http://0177.0.0.1/v1/audio/speech",
            "http://127.0.0.256/v1/audio/speech"
        ]

        for endpoint in refused {
            let url = try XCTUnwrap(URL(string: endpoint))
            XCTAssertFalse(
                EndpointTransportPolicy.permitsCredentials(url),
                "\(endpoint) does not name this machine's loopback interface."
            )
        }
    }

    func testEndpointsWithoutAnHTTPHostAreRefused() throws {
        // WHY: A hostless or non-HTTP endpoint has no transport the app can reason about, so it
        // must fail closed here as well as in the request builder that reports it to the user.
        let refused = [
            "http:///v1/audio/speech",
            "ftp://localhost/v1/audio/speech",
            "file:///v1/audio/speech",
            "data:text/plain,localhost"
        ]

        for endpoint in refused {
            let url = try XCTUnwrap(URL(string: endpoint))
            XCTAssertFalse(
                EndpointTransportPolicy.permitsCredentials(url),
                "\(endpoint) has no protected HTTP transport to permit."
            )
        }
    }

    func testOnlySchemeHostAndEffectivePortDecideThatTwoURLsShareAnOrigin() throws {
        // WHY: A provider that moves its speech endpoint within its own deployment must keep
        // working, so the comparison has to ignore everything that is not the origin — path, query,
        // userinfo — and read the spellings the same address can take: a default port written out,
        // and the case-insensitive scheme and host DNS and URL syntax both define.
        let sameOrigin = [
            ("https://custom.api/v1/audio/speech", "https://custom.api/v2/audio/speech"),
            ("https://custom.api/v1/audio/speech", "https://custom.api/v1/audio/speech?retry=1"),
            ("https://custom.api/v1/audio/speech", "https://custom.api:443/v1/audio/speech"),
            ("http://localhost:80/v1/audio/speech", "http://localhost/v1/audio/speech"),
            ("https://Custom.API/v1/audio/speech", "https://custom.api/v1/audio/speech"),
            ("HTTPS://custom.api/v1/audio/speech", "https://custom.api/v1/audio/speech"),
            ("https://user@custom.api/v1/audio/speech", "https://custom.api/v1/audio/speech")
        ]

        for (endpoint, target) in sameOrigin {
            let url = try XCTUnwrap(URL(string: endpoint))
            let other = try XCTUnwrap(URL(string: target))
            XCTAssertTrue(
                EndpointTransportPolicy.isSameOrigin(other, as: url),
                "\(target) is the same origin as \(endpoint) and must stay reachable."
            )
        }
    }

    func testADifferentScheme_Host_OrPortIsADifferentOrigin() throws {
        // WHY: Each of these sends the saved key somewhere its own endpoint never authorized — a
        // sibling host, another port on the same host, or the cleartext spelling of the same
        // address. The loopback pair differs in scheme alone, on a port both spellings state, which
        // is the one shape where the scheme has to be compared in its own right: everywhere else
        // the default port a scheme implies already separates the two. The last entries are forms
        // whose meaning depends on a second reading: a trailing-dot name, a scheme the app never
        // sends over — which matches nothing, its own repetition included, and states its own port
        // in the second spelling precisely because a URL that carries one must not thereby answer
        // for a scheme this rule does not know — and a hostless URL are refused rather than
        // resolved on the user's behalf, as the transport rule refuses their equivalents.
        let differentOrigin = [
            ("https://custom.api/v1/audio/speech", "https://other.api/v1/audio/speech"),
            ("https://custom.api/v1/audio/speech", "https://sub.custom.api/v1/audio/speech"),
            ("https://custom.api/v1/audio/speech", "https://custom.api:8443/v1/audio/speech"),
            ("https://custom.api:8443/v1/audio/speech", "https://custom.api/v1/audio/speech"),
            ("https://custom.api/v1/audio/speech", "http://custom.api/v1/audio/speech"),
            ("http://127.0.0.1:8080/v1/audio/speech", "https://127.0.0.1:8080/v1/audio/speech"),
            ("http://127.0.0.1:8080/v1/audio/speech", "http://localhost:8080/v1/audio/speech"),
            ("https://custom.api/v1/audio/speech", "https://custom.api./v1/audio/speech"),
            ("https://custom.api/v1/audio/speech", "ftp://custom.api/v1/audio/speech"),
            ("ftp://custom.api/v1/audio/speech", "ftp://custom.api/v1/audio/speech"),
            ("ftp://custom.api:21/v1/audio/speech", "ftp://custom.api:21/v1/audio/speech"),
            ("https://custom.api/v1/audio/speech", "https:///v1/audio/speech")
        ]

        for (endpoint, target) in differentOrigin {
            let url = try XCTUnwrap(URL(string: endpoint))
            let other = try XCTUnwrap(URL(string: target))
            XCTAssertFalse(
                EndpointTransportPolicy.isSameOrigin(other, as: url),
                "\(target) is not the origin \(endpoint) authorized to carry the key."
            )
        }
    }
}
