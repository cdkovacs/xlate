import Foundation
import WhisperKit

/// Whisper (large-v3-turbo, quantized for M1) via argmax-oss-swift. One pass
/// detects the language and transcribes; a third-language guess (es, gl) is
/// redone pinned to Portuguese.
///
/// Never downloads during a call: `prepare()` only loads what `installModel()`
/// already put on disk.
public actor WhisperTranscriber: Transcriber {
    public static let shared = WhisperTranscriber()
    public static let variant = "openai_whisper-large-v3-v20240930_626MB"

    public static var modelsBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xlate/Models", isDirectory: true)
    }

    private var pipe: WhisperKit?
    private let serializer = Serializer()

    public init() {}

    /// The one place that touches the network. Called from "Set up models…".
    public static func installModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let folder = try await WhisperKit.download(variant: variant, downloadBase: modelsBase) {
            progress?($0.fractionCompleted)
        }
        // Loading once with downloads allowed also caches the tokenizer next to the model.
        _ = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: modelsBase,
                                                  verbose: false, logLevel: .error, download: true))
    }

    static func installedFolder() -> URL? {
        let enumerator = FileManager.default.enumerator(at: modelsBase, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == variant { return url }
        }
        return nil
    }

    public func prepare() async throws -> EngineStatus {
        if pipe != nil { return .ready }
        guard let folder = Self.installedFolder() else { return .modelMissing("Whisper model") }
        pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.modelsBase,
                                                     verbose: false, logLevel: .error, prewarm: true,
                                                     load: true, download: false))
        return .ready
    }

    public func transcribe(_ utterance: Utterance) async throws -> Transcript {
        guard let pipe else { throw WhisperError.notPrepared }
        // WhisperKit isn't Sendable; the serializer keeps it to one utterance
        // at a time, even across a tap rebuild.
        nonisolated(unsafe) let whisper = pipe
        let samples = utterance.samples
        let (results, language) = try await serializer.run { () async throws -> ([String], SpokenLanguage) in
            try await Self.recognize(samples, with: whisper)
        }
        let text = results.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, language: text.isEmpty ? .unknown : language, duration: utterance.duration)
    }

    private static func recognize(_ samples: [Float], with pipe: WhisperKit) async throws -> ([String], SpokenLanguage) {
        // One pass with detection built in. Only a third-language guess (es, gl)
        // costs a second pass, pinned to Portuguese.
        var results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: nil))
        var language = Self.language(fromDetected: results.first?.language ?? "pt")
        if let code = results.first?.language, code != "pt", code != "en" {
            results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: "pt"))
            language = .portuguese
        }
        return (results.map(\.text), language)
    }

    static func options(language: String?) -> DecodingOptions {
        DecodingOptions(task: .transcribe, language: language, temperature: 0, usePrefillPrompt: language != nil,
                        detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true)
    }

    /// WhisperKit's `langProbs` holds only the chosen language's log-prob, so
    /// use the chosen code. Calls are Portuguese or English; Whisper's usual
    /// slips on Brazilian speech (es, gl) count as Portuguese.
    static func language(fromDetected code: String) -> SpokenLanguage {
        code == "en" ? .english : .portuguese
    }

    enum WhisperError: Error {
        case notPrepared
    }
}
