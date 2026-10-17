import Foundation
import Translation

public protocol Translator: Sendable {
    func prepare() async throws -> EngineStatus
    func translate(_ portuguese: String) async throws -> String
}

/// Apple's on-device Translation framework, Portuguese (Brazil) → English.
/// Uses the installed-languages initializer, which never downloads.
public actor AppleTranslator: Translator {
    static let source = Locale.Language(identifier: "pt-BR")
    static let target = Locale.Language(identifier: "en")

    private var session: TranslationSession?

    public init() {}

    public func prepare() async throws -> EngineStatus {
        if session != nil { return .ready }
        let status = await LanguageAvailability().status(from: Self.source, to: Self.target)
        guard status == .installed else { return .modelMissing("Portuguese → English translation") }
        let session = TranslationSession(installedSource: Self.source, target: Self.target)
        self.session = session
        // The model loads lazily; on a live call the first few captions took
        // 3.5 to 8.7 s. One throwaway translation here pays that up front.
        _ = try? await translate("Olá, tudo bem?")
        return .ready
    }

    public func translate(_ portuguese: String) async throws -> String {
        guard let session else { throw TranslatorError.notPrepared }
        // TranslationSession isn't Sendable. CaptionPipeline translates one
        // caption at a time, so the session is never used concurrently.
        nonisolated(unsafe) let unchecked = session
        return try await unchecked.translate(portuguese).targetText
    }

    enum TranslatorError: Error {
        case notPrepared
    }
}
