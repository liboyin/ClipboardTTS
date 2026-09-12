import XCTest
@testable import ClipboardTTSApp

/// The rule deciding what a speech response has to declare before its bytes may be played as PCM.
final class SpeechResponseFormatPolicyTests: XCTestCase {
    func testAResponseBodyDeclaringNoContentTypeIsStillReadAsPCM() {
        // WHY: OpenAI's own API reference documents no content type for its speech endpoint, so an
        // endpoint that sends none, or sends an empty one, is behaving ordinarily. Refusing it
        // would refuse the provider this app was built against. Only silence qualifies: a value
        // carrying parameters and no type has said something, and says nothing this app can read.
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: nil))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: ""))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: "   "))
        XCTAssertFalse(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: "; charset=utf-8"))
        XCTAssertFalse(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: "; charset=utf-8"))
    }

    func testADeclarationWhoseTypeOrSubtypeIsNotAnHTTPTokenIsRefused() {
        // WHY: The audio tree is accepted without inspecting the subtype, so whether a value is a
        // media type at all is the only thing left standing between a provider-controlled header
        // and the player. A subtype of "()" or an emoji is not a token and not a declaration, and
        // reading it as one would let the leading "audio/" carry an arbitrary body into playback.
        for declaredContentType in [
            "audio/()",
            "audio/💥",
            "audio/pc m",
            "audio/\"pcm\"",
            "audio/pcm@raw",
            "au dio/pcm"
        ] {
            XCTAssertFalse(
                SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: declaredContentType),
                "\(declaredContentType) is not a media type and must not reach the player."
            )
            XCTAssertFalse(
                SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: declaredContentType),
                "\(declaredContentType) is not a media type and must not be decoded."
            )
        }
    }

    func testADeclarationSpelledOnlyWithTokenCharactersIsStillRead() {
        // WHY: An HTTP token allows more than letters, and a subtype using the rest of that set is
        // ordinary rather than suspect. Validating tokens too narrowly would refuse a working
        // endpoint, which is the failure this whole rule is written to avoid.
        for declaredContentType in ["audio/x-pcm.raw+le", "audio/vnd.wave", "audio/l16;rate=24000"] {
            XCTAssertTrue(
                SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: declaredContentType),
                "\(declaredContentType) is a well-formed audio declaration and must reach the player."
            )
        }
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: "audio/l16;codec=pcm;rate=24000"))
    }

    func testAResponseBodyDeclaringAnyAudioTypeIsReadAsPCM() {
        // WHY: Which type an OpenAI-compatible server labels raw samples with is documented
        // nowhere, so the subtype is deliberately not inspected: narrowing it here would refuse a
        // working deployment on a guess rather than on evidence.
        for declaredContentType in ["audio/pcm", "audio/L16", "audio/wav", "audio/mpeg", "audio/x-pcm"] {
            XCTAssertTrue(
                SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: declaredContentType),
                "\(declaredContentType) declares audio and must reach the player."
            )
        }
    }

    func testAResponseBodyDeclaringGenericBinaryIsReadAsPCM() {
        // WHY: An endpoint streaming raw samples has no more specific type to send. These are the
        // generic spellings the accepted decision names, and a parameter must not change the answer.
        for declaredContentType in ["application/octet-stream", "binary/octet-stream", "application/octet-stream; charset=binary"] {
            XCTAssertTrue(
                SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: declaredContentType),
                "\(declaredContentType) declares opaque bytes and must reach the player."
            )
        }
    }

    func testAResponseBodyDeclaringSomethingOtherThanAudioIsRefused() {
        // WHY: This is the defect. A provider that answers HTTP 200 with a JSON error, an event
        // stream, or a document is not returning audio, and playing those bytes as 16-bit samples
        // renders them as full-scale noise rather than as a failure the user can read.
        for declaredContentType in [
            "application/json",
            "application/json; charset=utf-8",
            "text/plain",
            "text/event-stream",
            "application/pdf",
            "image/png",
            "video/mp4"
        ] {
            XCTAssertFalse(
                SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: declaredContentType),
                "\(declaredContentType) declares something other than audio and must not reach the player."
            )
        }
    }

    func testADeclarationIsReadWithoutRegardToCaseOrItsParameters() {
        // WHY: A media type's type and subtype are case-insensitive, and parameters qualify a type
        // rather than replace it. Gemini's own declaration carries two parameters, so a rule that
        // compared the raw header would refuse the provider it was written for.
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: "AUDIO/PCM"))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: "Audio/L16;codec=pcm;rate=24000"))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: "AUDIO/L16"))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: "audio/L16;codec=pcm;rate=24000"))
        XCTAssertFalse(SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: "APPLICATION/JSON; CHARSET=UTF-8"))
    }

    func testADeclarationThatIsNotOneMediaTypeIsRefused() {
        // WHY: URLSession joins repeated headers into one value, so a response that declared two
        // content types arrives as one string naming both. It has not declared what its body is,
        // and believing whichever half came first would let an audio type excuse the other. A value
        // that is not a type and subtype at all is refused for the same reason: it is a declaration
        // this app could not read, not the silence it treats as undeclared.
        for declaredContentType in [
            "application/json, audio/pcm",
            "audio/pcm, application/json",
            "audio/pcm, audio/wav",
            "audio/pcm; rate=24000, application/json",
            "audio/pcm, whatever",
            "audio",
            "audio/",
            "/pcm",
            "audio/pcm/raw"
        ] {
            XCTAssertFalse(
                SpeechResponseFormatPolicy.permitsPCMBody(declaredContentType: declaredContentType),
                "\(declaredContentType) is not one readable media type and must not reach the player."
            )
            XCTAssertFalse(
                SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: declaredContentType),
                "\(declaredContentType) is not one readable media type and must not be decoded."
            )
        }
    }

    func testAnInlinePayloadDeclaringNoMediaTypeIsStillDecodedAsPCM() {
        // WHY: The request asks for the AUDIO response modality alone, so a part arriving under it
        // is audio by the terms of the request. Refusing an undeclared part would trade a defect
        // nothing has produced for the loss of every Gemini utterance if the field were omitted.
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: nil))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: ""))
    }

    func testAnInlinePayloadDeclaringLinearPCMIsDecoded() {
        // WHY: These are the two spellings Google publishes for the same raw 16-bit samples —
        // audio/L16 from the speech endpoint this app calls, audio/pcm from the Live API — so both
        // have to pass or the provider's own output would be refused.
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: "audio/L16;codec=pcm;rate=24000"))
        XCTAssertTrue(SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: "audio/pcm;rate=24000"))
    }

    func testAnInlinePayloadDeclaringAnythingElseIsRefused() {
        // WHY: Gemini's inline blob is the same type that carries images, video, documents, and
        // text elsewhere in the API, and its schema lists exactly those as supported media. Unlike
        // a configurable OpenAI-compatible endpoint, one fixed provider's own audio declaration is
        // documented, so the accepted set here can be exact — a container format is refused too,
        // because the decoder reads these bytes as raw samples and nothing unwraps a container.
        for declaredMediaType in [
            "application/pdf",
            "application/json",
            "image/png",
            "text/plain",
            "audio/mpeg",
            "audio/wav",
            "application/octet-stream"
        ] {
            XCTAssertFalse(
                SpeechResponseFormatPolicy.permitsInlinePCM(declaredMediaType: declaredMediaType),
                "\(declaredMediaType) is not the linear PCM the Gemini decoder reads."
            )
        }
    }
}
