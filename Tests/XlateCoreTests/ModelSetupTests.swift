import Testing
@testable import XlateCore

@Test func everythingInstalledNeedsNothing() {
    #expect(ModelSetup.nextStep(speechInstalled: true, translationInstalled: true) == .allReady)
}

@Test func missingSpeechModelDownloadsFirst() {
    #expect(ModelSetup.nextStep(speechInstalled: false, translationInstalled: true) == .downloadSpeech)
    #expect(ModelSetup.nextStep(speechInstalled: false, translationInstalled: false) == .downloadSpeech)
}

@Test func missingTranslationSendsToSettings() {
    #expect(ModelSetup.nextStep(speechInstalled: true, translationInstalled: false) == .installTranslation)
}
