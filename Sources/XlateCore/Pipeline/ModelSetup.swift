/// What "Set Up Models…" should do next. The speech model is ours to
/// download; the translation language installs from System Settings.
public enum ModelSetup {
    public enum Step: Sendable, Equatable {
        case allReady
        case downloadSpeech
        case installTranslation
    }

    public static func nextStep(speechInstalled: Bool, translationInstalled: Bool) -> Step {
        if !speechInstalled { return .downloadSpeech }
        if !translationInstalled { return .installTranslation }
        return .allReady
    }
}
