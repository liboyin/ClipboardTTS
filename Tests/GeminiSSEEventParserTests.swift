import XCTest
@testable import ClipboardTTSApp

final class GeminiSSEEventParserTests: XCTestCase {
    func testOneByteFragmentsJoinMultilineDataAndSearchEachByteOnce() throws {
        // WHY: Parsing runs while request state is held. Rescanning the unfinished line on every
        // packet makes one large event quadratic, and Gemini 2.5 models send a whole utterance as
        // one event.
        let stream = Data("data: first\r\n: comment\nevent: audio\ndata:second\r\n\r\n".utf8)
        var parser = GeminiSSEEventParser()
        var payloads: [Data] = []

        for byte in stream {
            payloads += try parser.append(Data([byte]))
        }

        XCTAssertEqual(payloads, [Data("first\nsecond".utf8)])
        XCTAssertEqual(parser.searchedByteCount, stream.count)
        XCTAssertFalse(parser.hasIncompleteEvent)
    }

    func testUnterminatedLineGrowingAcrossPacketsIsSearchedOnce() throws {
        // WHY: The bytes of an unfinished line are known to hold no line ending. Searching them
        // again for each packet is the cost this parser exists to avoid.
        var parser = GeminiSSEEventParser()
        let packet = Data(repeating: UInt8(ascii: "A"), count: 1024)
        var received = 0

        XCTAssertEqual(try parser.append(Data("data: ".utf8)), [])
        received += 6
        for _ in 0..<256 {
            XCTAssertEqual(try parser.append(packet), [])
            received += packet.count
        }

        XCTAssertEqual(parser.searchedByteCount, received)
        XCTAssertTrue(parser.hasIncompleteEvent)
        XCTAssertEqual(try parser.append(Data("\n\n".utf8)), [Data(repeating: UInt8(ascii: "A"), count: 256 * 1024)])
        XCTAssertEqual(parser.searchedByteCount, received + 2)
    }

    func testCarriageReturnArrivingBeforeItsLineFeedEndsTheLine() throws {
        // WHY: URLSession may split a CRLF pair between callbacks. The CR must not end up in the
        // payload, and the event must not end before its LF arrives.
        var parser = GeminiSSEEventParser()

        XCTAssertEqual(try parser.append(Data("data: {}\r".utf8)), [])
        XCTAssertEqual(try parser.append(Data("\n\r".utf8)), [])
        XCTAssertEqual(try parser.append(Data("\n".utf8)), [Data("{}".utf8)])
    }

    func testEventChargedExactlyTheCapCompletesHoweverItIsSplit() throws {
        // WHY: The cap bounds memory without refusing the largest event it admits, and where
        // URLSession happens to split the stream must not decide whether an event fits.
        let event = Data("data: 0123\ndata:\r\n\n".utf8)
        // Ten raw bytes, then six for an empty data line with its CR: sixteen, which is the cap.
        let expected = [Data("0123\n".utf8)]

        var whole = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)
        XCTAssertEqual(try whole.append(event), expected)
        var bytewise = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)
        var payloads: [Data] = []
        for byte in event {
            payloads += try bytewise.append(Data([byte]))
        }
        XCTAssertEqual(payloads, expected)
    }

    func testUnfinishedLineOneByteOverTheCapFails() {
        // WHY: An event that never ends must not grow request-owned memory without bound.
        var parser = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)

        XCTAssertThrowsError(try parser.append(Data("data: 0123456789A".utf8))) { error in
            XCTAssertTrue(error is GeminiSSEEventParser.UnfinishedEventTooLarge)
        }
    }

    func testOverCapEventEndingInTheSameCallbackFails() {
        // WHY: Checking only between callbacks would let a callback that also ends the event hand
        // an over-cap payload to JSON and base64 decoding.
        var parser = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)

        XCTAssertThrowsError(try parser.append(Data("data: 0123456789A\n\n".utf8)))
    }

    func testOverCapCommentLineFailsEvenWhenItEndsInOneCallback() {
        // WHY: A line the parser will discard still has to be held until its line feed arrives,
        // so split across callbacks it fails the cap. Letting it pass whole would make the verdict
        // depend on where URLSession split the stream.
        var parser = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)

        XCTAssertThrowsError(try parser.append(Data(": 0123456789ABCDE\n".utf8)))
    }

    func testCompletedDataLinesCountTowardTheCap() throws {
        // WHY: An event can grow through many short data lines as well as one long line; only
        // charging the unfinished line would leave that growth unbounded.
        var parser = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)

        XCTAssertEqual(try parser.append(Data("data: 0123\n".utf8)), [])
        XCTAssertThrowsError(try parser.append(Data("data: 1\n".utf8)))
    }

    func testEmptyDataLinesCountTowardTheCap() throws {
        // WHY: An empty data line adds a separator and an array entry but no value. Charging only
        // values would let a stream of them grow an event without bound.
        var parser = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)

        XCTAssertEqual(try parser.append(Data("data:\ndata:\ndata:\n".utf8)), [])
        XCTAssertThrowsError(try parser.append(Data("data:\n".utf8)))
    }

    func testCompletingAnEventReleasesItsShareOfTheCap() throws {
        // WHY: The cap applies to one event. A long stream of events, each under it, must keep
        // playing.
        var parser = GeminiSSEEventParser(maximumUnfinishedEventByteCount: 16)

        for _ in 0..<3 {
            XCTAssertEqual(try parser.append(Data("data: 0123456789\n\n".utf8)), [Data("0123456789".utf8)])
        }
    }

    func testDefaultCapAdmitsTheLargestDocumentedGeminiEvent() throws {
        // WHY: D13 sizes the cap from Google's documented output limit: 16,384 tokens at 25 audio
        // tokens per second is 655.36 s of 24-kHz 16-bit mono PCM. A 2.5 model sends all of it
        // as one event, and a lower cap would refuse that utterance.
        let pcmByteCount = 16_384 * 48_000 / 25
        let base64ByteCount = (pcmByteCount + 2) / 3 * 4
        let prefix = Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"data\":\"".utf8)
        let suffix = Data("\"}}]}}]}\n\n".utf8)
        var parser = GeminiSSEEventParser()
        var payloads = try parser.append(prefix)
        let chunk = Data(repeating: UInt8(ascii: "A"), count: 1 << 20)
        var remaining = base64ByteCount
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            payloads += try parser.append(chunk.prefix(count))
            remaining -= count
        }
        payloads += try parser.append(suffix)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.count, prefix.count - 6 + base64ByteCount + suffix.count - 2)
    }
}
