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
}
