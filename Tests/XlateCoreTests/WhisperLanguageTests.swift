import Testing
@testable import XlateCore

@Test(arguments: [("pt", SpokenLanguage.portuguese), ("en", .english), ("es", .portuguese), ("gl", .portuguese)])
func detectedLanguageMapsToCallLanguages(_ code: String, _ expected: SpokenLanguage) {
    #expect(WhisperTranscriber.language(fromDetected: code) == expected)
}
