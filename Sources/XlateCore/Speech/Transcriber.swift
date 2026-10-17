public enum SpokenLanguage: Sendable, Equatable {
    case portuguese, english, unknown
}

public struct Transcript: Sendable, Equatable {
    public let text: String
    public let language: SpokenLanguage
    public let duration: Double

    public init(text: String, language: SpokenLanguage, duration: Double) {
        self.text = text
        self.language = language
        self.duration = duration
    }
}

/// Whether an on-device engine can run without fetching anything.
public enum EngineStatus: Sendable, Equatable {
    case ready
    case modelMissing(String)
}

public protocol Transcriber: Sendable {
    func prepare() async throws -> EngineStatus
    func transcribe(_ utterance: Utterance) async throws -> Transcript
}
