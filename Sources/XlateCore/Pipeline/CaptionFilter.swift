/// What the pill shows: the English with the Portuguese it came from.
public struct Caption: Sendable, Equatable {
    public let english: String
    public let portuguese: String

    public init(english: String, portuguese: String) {
        self.english = english
        self.portuguese = portuguese
    }
}

/// Decides whether a transcript is worth a caption. English never is, and
/// one-word or very short results are usually a chime, a cough or "é".
public enum CaptionFilter {
    public static let minimumWords = 2
    public static let minimumDuration = 0.5

    public static func accepts(_ transcript: Transcript) -> Bool {
        transcript.language == .portuguese
            && transcript.duration >= minimumDuration
            && transcript.text.split(whereSeparator: \.isWhitespace).count >= minimumWords
    }
}
