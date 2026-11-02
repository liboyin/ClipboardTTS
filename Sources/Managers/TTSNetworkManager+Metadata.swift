import Foundation

/// A published model or voice suggestion list together with the provider it was fetched for.
///
/// Settings renders a newly selected provider's saved model and voice one render before its
/// `onChange` can resynchronize the manager, so the previous provider's list is still published at
/// that point. Naming the owner on the list itself is what lets a form refuse it: SwiftUI documents
/// a picker whose selection has no matching tag as undefined, and offering one provider's choices
/// under another provider's configuration would be wrong even where it is defined.
struct ProviderSuggestions: Equatable {
    /// The state before any list is published, and the one an invalidated metadata scope returns to.
    static let unpublished = ProviderSuggestions(provider: nil, values: [])

    /// The provider these suggestions were fetched for, if a catalog was published.
    let provider: APIKeyProvider?
    let values: [String]

    /// The suggestions when they belong to `provider`, and none otherwise.
    func values(for provider: APIKeyProvider) -> [String] {
        self.provider == provider ? values : []
    }
}

extension TTSNetworkManager {
    enum MetadataKind {
        case models
        case voices
    }

    struct MetadataRequestToken: Equatable {
        let identifier: UInt64
        let generation: UInt64
        /// The provider this request's results may be published for, carried on the token so a
        /// publication takes its identity from the request that earned it rather than from settings
        /// that may have changed since.
        let provider: APIKeyProvider
    }

    /// How one metadata request's completion was handled, as reported to the manager's
    /// `metadataCompletionObserver`.
    struct MetadataCompletion: Equatable {
        enum Outcome: Equatable {
            /// The request was still current, and its list has been published.
            case published
            /// The request was still current, and it released its slot without publishing.
            case abandoned
            /// The request had already been replaced or invalidated, so its completion changed nothing.
            case superseded
        }

        let kind: MetadataKind
        let token: MetadataRequestToken
        let outcome: Outcome
    }

    private struct MetadataSource: Equatable {
        let baseURL: String
        let provider: APIKeyProvider
    }

    private func beginMetadataRequest(for kind: MetadataKind,
                                      source: MetadataSource) -> MetadataRequestToken? {
        stateQueue.sync {
            guard requestSettings.baseURL == source.baseURL,
                  requestSettings.provider == source.provider else { return nil }

            nextMetadataRequestIdentifier &+= 1
            let token = MetadataRequestToken(
                identifier: nextMetadataRequestIdentifier,
                generation: metadataGeneration,
                provider: source.provider
            )
            switch kind {
            case .models:
                modelMetadataToken = token
            case .voices:
                voiceMetadataToken = token
            }
            return token
        }
    }

    /// Clears the request `token` owns on behalf of a caller that abandons it without publishing.
    ///
    /// Delegates to `completeMetadataRequest` rather than repeating its switch, so one token guard
    /// owns the transition and an abandonment cannot drift from the completion the publication path
    /// guards on. `stateQueue` is serial, so this must not wrap the call in a `sync` block of its own.
    /// The completion observer is told the guard's answer on the caller's thread once it is final.
    private func finishMetadataRequest(for kind: MetadataKind, token: MetadataRequestToken) {
        let isCurrent = completeMetadataRequest(for: kind, token: token)
        metadataCompletionObserver(
            MetadataCompletion(kind: kind, token: token, outcome: isCurrent ? .abandoned : .superseded)
        )
    }

    private func publishMetadata(_ values: [String],
                                 for kind: MetadataKind,
                                 token: MetadataRequestToken) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard self.completeMetadataRequest(for: kind, token: token) else {
                self.metadataCompletionObserver(MetadataCompletion(kind: kind, token: token, outcome: .superseded))
                return
            }
            do {
                self.isPublishingMetadata = true
                defer { self.isPublishingMetadata = false }
                let suggestions = ProviderSuggestions(provider: token.provider, values: values)
                switch kind {
                case .models:
                    self.modelSuggestions = suggestions
                case .voices:
                    self.voiceSuggestions = suggestions
                }
            }
            self.metadataCompletionObserver(MetadataCompletion(kind: kind, token: token, outcome: .published))
        }
    }

    /// Clears the request `token` owns, reporting whether it was still the current one.
    ///
    /// The single owner of this transition: a completion may only clear the request it belongs to,
    /// so one whose request was already replaced is told `false` and must publish nothing.
    private func completeMetadataRequest(for kind: MetadataKind, token: MetadataRequestToken) -> Bool {
        stateQueue.sync {
            switch kind {
            case .models where modelMetadataToken == token:
                modelMetadataToken = nil
                return true
            case .voices where voiceMetadataToken == token:
                voiceMetadataToken = nil
                return true
            default:
                return false
            }
        }
    }

    #if DEBUG
    /// Returns a pending token so tests can simulate a completion already queued at cancellation time.
    func metadataTokenForTesting(for kind: MetadataKind) -> MetadataRequestToken? {
        stateQueue.sync {
            switch kind {
            case .models:
                return modelMetadataToken
            case .voices:
                return voiceMetadataToken
            }
        }
    }

    /// Delivers a synthetic late completion through the production publication guard.
    func publishMetadataForTesting(_ values: [String],
                                   for kind: MetadataKind,
                                   token: MetadataRequestToken) {
        publishMetadata(values, for: kind, token: token)
    }

    /// Delivers a synthetic late abandonment through the production completion guard.
    ///
    /// The counterpart to `publishMetadataForTesting`: it makes the abandonment half of the race
    /// deterministic, which main-queue timing alone cannot.
    func finishMetadataRequestForTesting(for kind: MetadataKind, token: MetadataRequestToken) {
        finishMetadataRequest(for: kind, token: token)
    }
    #endif

    func clearMetadataLists(for generation: UInt64) {
        let clearLists: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            guard self.stateQueue.sync(execute: { self.metadataGeneration == generation }) else { return }
            self.modelSuggestions = .unpublished
            self.voiceSuggestions = .unpublished
        }

        if Thread.isMainThread, !isPublishingMetadata {
            clearLists()
        } else {
            DispatchQueue.main.async(execute: clearLists)
        }
    }

    /// Publishes the selected provider's documented model catalog, replacing only an equally current
    /// model request.
    ///
    /// No provider the app supports needs a model request: `ProviderMetadataCatalog` states the
    /// speech models OpenAI and Gemini offer, and a Custom endpoint documents nothing, so its request
    /// is abandoned without publishing. The catalog still travels the guarded token path, because
    /// publication is asynchronous and a provider or endpoint the user changes in that window must
    /// invalidate it.
    func fetchAvailableModels(baseURL: String, selectedProvider: String) {
        let source = MetadataSource(
            baseURL: baseURL,
            provider: APIKeyProvider(selectedProvider: selectedProvider)
        )
        guard let token = beginMetadataRequest(for: .models, source: source) else { return }
        guard let models = ProviderMetadataCatalog.models(for: source.provider) else {
            finishMetadataRequest(for: .models, token: token)
            return
        }
        publishMetadata(models, for: .models, token: token)
    }

    /// Publishes the selected provider's documented voice catalog, replacing only an equally current
    /// voice request.
    ///
    /// No provider the app supports offers voice discovery, so this creates no request and needs no
    /// credential: `ProviderMetadataCatalog` states what OpenAI and Gemini document, and a Custom
    /// endpoint documents nothing, which is why `SettingsView.syncSettings` does not ask for one.
    /// The catalog still travels the guarded token path, because publication is asynchronous and a
    /// provider or endpoint the user changes in that window must invalidate it.
    func fetchAvailableVoices(baseURL: String, selectedProvider: String) {
        let source = MetadataSource(
            baseURL: baseURL,
            provider: APIKeyProvider(selectedProvider: selectedProvider)
        )
        guard let token = beginMetadataRequest(for: .voices, source: source) else { return }
        guard let voices = ProviderMetadataCatalog.voices(for: source.provider) else {
            finishMetadataRequest(for: .voices, token: token)
            return
        }
        publishMetadata(voices, for: .voices, token: token)
    }
}
