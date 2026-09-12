import Foundation

/// Decides whether what a speech response declares itself to be may be read as 16-bit PCM.
///
/// Every byte this app plays is interpreted as raw little-endian 16-bit samples, so a body that is
/// anything else — a JSON error the provider returned with HTTP 200, an event stream, a container
/// format, a PDF — is not silently unplayable but audibly wrong: it renders as full-scale noise.
/// The declaration is the only thing available to refuse it by, because the app asks for raw samples
/// precisely so that nothing about the body identifies itself.
///
/// Both rules below accept a response that declared nothing, and refuse one whose declaration names
/// something else. That asymmetry is deliberate: refusing silence would be a guess about a provider
/// this app cannot cite, while a declaration is the provider's own answer about its body. The two
/// questions differ only in how much is documented about which answers are right.
enum SpeechResponseFormatPolicy {
    /// The declarations that name a body as opaque bytes rather than as a format.
    ///
    /// An endpoint that streams raw samples has no better type to send, so these are the generic
    /// spellings D4 accepts alongside an omitted header.
    private static let genericBinaryTypes: Set<String> = ["application/octet-stream", "binary/octet-stream"]

    /// The declarations that name raw linear 16-bit PCM, which is what the Gemini decoder reads.
    ///
    /// `audio/L16` is what Gemini's speech output declares, as `audio/L16;codec=pcm;rate=24000`;
    /// `audio/pcm` is the spelling Google's Live API uses for the same samples. Both are listed
    /// because one provider uses both, not as an allowance for any other subtype.
    private static let linearPCMTypes: Set<String> = ["audio/l16", "audio/pcm"]

    /// What a response said about its own media, reduced to the three answers the rules act on.
    private enum Declaration {
        /// Nothing was declared. Both rules read this as the provider having said nothing at all.
        case absent
        /// One media type, as its lowercased type and subtype with any parameters dropped.
        case single(String)
        /// Something was declared, but it is not one media type — most often several at once.
        case unreadable
    }

    /// Returns whether an OpenAI-compatible speech response body may be delivered as PCM.
    ///
    /// The subtype is deliberately not inspected. OpenAI's own API reference documents no content
    /// type for `/v1/audio/speech` at all, so which type a compatible server labels raw samples with
    /// is unknown, and narrowing `audio/*` here would refuse a working deployment on a guess. What
    /// is knowable is the opposite: a declaration outside the audio tree, and outside the generic
    /// binary types, says the body is not audio at all.
    ///
    /// Only requests that ask for raw samples use this. Gemini's own transport is Server-Sent
    /// Events, whose payload carries its own declaration; see `permitsInlinePCM(declaredMediaType:)`.
    static func permitsPCMBody(declaredContentType: String?) -> Bool {
        switch declaration(in: declaredContentType) {
        case .absent:
            return true
        case .unreadable:
            return false
        case let .single(essence):
            return essence.hasPrefix("audio/") || genericBinaryTypes.contains(essence)
        }
    }

    /// Returns whether a Gemini inline payload may be decoded as PCM and delivered.
    ///
    /// Gemini's `inlineData` is the same blob type that carries images, video, PDFs, and text
    /// elsewhere in the API, and the schema documents exactly those as supported media, so a part
    /// this app hands to the player unread is one it has taken on faith. Here the accepted set can
    /// be exact rather than open, because a single provider at a fixed endpoint publishes what its
    /// speech output declares.
    ///
    /// An absent declaration is still accepted: the request asks for the `AUDIO` response modality
    /// alone, so a part arriving under it is audio by the terms of the request, and refusing an
    /// undeclared one would trade a defect nothing has produced for the loss of every Gemini
    /// utterance if the field were ever omitted. The caller passes nil for a `mimeType` of another
    /// JSON type for the same reason a `finishReason` of another type is treated as undeclared: a
    /// value the app cannot read names no media, where a readable one that names other media does.
    static func permitsInlinePCM(declaredMediaType: String?) -> Bool {
        switch declaration(in: declaredMediaType) {
        case .absent:
            return true
        case .unreadable:
            return false
        case let .single(essence):
            return linearPCMTypes.contains(essence)
        }
    }

    /// The characters HTTP allows in the type and subtype of a media type, lowercased.
    ///
    /// This is RFC 9110's `tchar` set with the uppercase letters left out, because a declaration is
    /// folded to lower case before it is read. Anything outside it — a space, a quote, a bracket,
    /// any non-ASCII character — is a delimiter or is not allowed at all, so a component carrying
    /// one is not a media type however much of it looks like one.
    private static let tokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz")

    /// Reduces a declared media type to the answer the rules match against.
    ///
    /// Only a value the header omits entirely, or one that is nothing but whitespace, counts as
    /// silence. Everything else is a declaration the provider made, and it has to be a whole one:
    /// a type and a subtype that are both HTTP tokens. Anything short of that is unreadable rather
    /// than absent, which is the fail-closed half of the asymmetry these rules rest on — a value
    /// carrying only parameters, or a subtype such as `()` or an emoji, would otherwise be read as
    /// though the provider had said nothing while it was in fact saying something malformed.
    ///
    /// Parameters are dropped because they qualify a type rather than change it: `audio/L16` and
    /// `audio/L16;codec=pcm;rate=24000` name the same samples, and a `charset` says nothing about
    /// whether a body is audio. Case is folded because a media type's type and subtype are defined
    /// case-insensitively, so `AUDIO/PCM` and `audio/pcm` are one declaration. A value carrying a
    /// comma is unreadable before any of that: URLSession joins repeated headers into one string,
    /// so that is a response declaring several types, which has not declared what its body is —
    /// and reading only as far as the first parameter would let its leading half excuse the rest.
    private static func declaration(in declaredMediaType: String?) -> Declaration {
        guard let declaredMediaType else { return .absent }
        let declaration = declaredMediaType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !declaration.isEmpty else { return .absent }
        guard !declaration.contains(",") else { return .unreadable }
        let essence = declaration
            .prefix { $0 != ";" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let components = essence.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, isToken(components[0]), isToken(components[1]) else {
            return .unreadable
        }
        return .single(essence)
    }

    /// Returns whether one component of a folded media type is a nonempty HTTP token.
    private static func isToken(_ component: Substring) -> Bool {
        !component.isEmpty && component.allSatisfy { tokenCharacters.contains($0) }
    }
}
