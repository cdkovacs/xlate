# Teams PT-BR Live Captions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar Mac app that taps Microsoft Teams' audio output, transcribes Brazilian Portuguese on-device, translates it to English on-device, and shows it in a floating pill.

**Architecture:** One SwiftPM package. `XlateCore` holds everything testable (process discovery, tap, speech gate, engine protocols, pipeline, wake state machine, pill timing). `Xlate` is the AppKit executable (menu bar, pill panel, wiring) and also hosts developer subcommands (`--dev ...`) so every spike runs inside the signed `.app` and uses the same audio capture permission. Engine choice is made by a measured spike in Task 5; everything downstream depends only on the `Transcriber` and `Translator` protocols.

**Tech Stack:** Swift 6.4 (Command Line Tools 27, no Xcode), SwiftPM with `--build-system native`, Swift Testing, Core Audio process taps, AVFoundation, Speech (`SpeechAnalyzer`/`SpeechTranscriber`), Translation (`TranslationSession`), NaturalLanguage, optionally `argmax-oss-swift` (WhisperKit), AppKit + SwiftUI, ServiceManagement.

**Spec:** `docs/superpowers/specs/2026-10-16-teams-ptbr-captions-design.md`

## Global Constraints

- macOS 26 minimum; runs only on this M1 Max. No App Store, no notarization.
- Target app bundle ID: `com.microsoft.teams2` (verified 2026-10-16 via `mdls`). Helpers live under `Microsoft Teams.app/Contents/Helpers/` (`Microsoft Teams WebView.app`, `Microsoft Teams ModuleHost.app`). Keep the bundle ID in one constant, `TargetApp.teamsBundleID`.
- No network traffic carrying audio or text at runtime. Model/language downloads happen only from an explicit setup action.
- Nothing about a call is written to disk. The only exception is `--dev tap --wav <path>` and the `XLATE_DEBUG_AUDIO_DIR` env var, both off unless explicitly given. No `print`/`os_log` of transcript or translation text outside `--dev` commands.
- English speech never reaches the pill. Portuguese shows as English line (≈15 pt, white) over Portuguese line (≈12 pt, italic, muted grey).
- Pill: ≈400 pt wide, rounded dark translucent, green live dot, default centered near top of main screen, draggable, non-activating, floats over full-screen apps and all Spaces, fades after 8 s without a new caption. Persist position only (`UserDefaults` key `pillOrigin`).
- Target latency ≤ 3 s from end of phrase to pill.
- Signing: self-signed identity named `xlate-local`, created once, reused for every build. Never sign with any other identity in the keychain.
- `Info.plist` must contain `NSAudioCaptureUsageDescription`; verify in the built bundle with `plutil`.
- Commits: imperative subject ≤ 50 chars, body says why. No AI attribution trailers (user's global rule).
- Before adding any dependency or using any API from this plan, confirm the current version/signature against official docs or the package registry and note the date in the commit body.

## Review Focus

1. **Output device changes mid-call** (AirPods connect, display audio switches): the aggregate device for the tap must be rebuilt and captions keep flowing. Test in Task 3.
2. **Teams restarts or a helper process is replaced mid-call** (PID changes): the wake monitor re-resolves processes and re-attaches. Test in Task 8.
3. **Long monologue with no pauses:** the speech gate force-cuts at 12 s so the pill updates. Test in Task 4.
4. **Portuguese sentence full of English tech loanwords** ("vamos fazer o deploy depois da sprint review") gets classified English and silently dropped. Must classify Portuguese. Test in Task 7.
5. **Saved pill position off-screen** after unplugging a monitor: clamp to the visible frame of the screen with the mouse, else main screen. Test in Task 9.

---

## File Structure

```
Package.swift
.gitignore                         .build/, build/, *.wav, fixtures/out/
Resources/Info.plist               LSUIElement, NSAudioCaptureUsageDescription, bundle id dev.ckovacs.xlate
scripts/test.sh                    swift test with CLT Testing framework flags
scripts/make-cert.sh               one-time xlate-local self-signed identity
scripts/bundle.sh                  build release, assemble build/Xlate.app, sign
scripts/make-fixtures.sh           `say` + afconvert → fixtures/out/*.wav + *.txt
Sources/XlateCore/
  TargetApp.swift                  bundle id constants
  Audio/AudioProcesses.swift       Core Audio process list, bundle ids, isRunningOutput
  Audio/ProcessTap.swift           tap + private aggregate device → AsyncStream<AudioChunk>
  Audio/AudioChunk.swift           16 kHz mono Float32 samples + host time
  Speech/SpeechGate.swift          energy VAD + segmentation → Utterance
  Speech/Transcriber.swift         protocol + Transcript + SpokenLanguage
  Speech/<Chosen>Transcriber.swift chosen in Task 5
  Translate/Translator.swift       protocol + AppleTranslator
  Pipeline/CaptionFilter.swift     pure accept/reject of a Transcript
  Pipeline/CaptionPipeline.swift   actor: chunks → gate → transcriber → filter → translator → Caption
  Wake/WakeMonitor.swift           pure state machine + Core Audio polling adapter
  UI/PillTiming.swift              pure fade + position clamp logic
Sources/Xlate/
  main.swift                       --dev dispatch, else NSApplication accessory app
  DevCommands.swift                procs, tap, engines, pill-demo, play-target
  AppDelegate.swift                status item menu, wiring, login item
  PillPanel.swift                  NSPanel subclass + SwiftUI PillView
Tests/XlateCoreTests/              one file per XlateCore unit
docs/engine-decision.md            Task 5 measurements and choice
```

---

### Task 1: Scaffold, test runner, signed app bundle

**Files:**
- Create: `Package.swift`, `.gitignore`, `Resources/Info.plist`, `scripts/test.sh`, `scripts/make-cert.sh`, `scripts/bundle.sh`, `Sources/XlateCore/TargetApp.swift`, `Sources/Xlate/main.swift`, `Tests/XlateCoreTests/TargetAppTests.swift`

**Interfaces:**
- Produces: `public enum TargetApp { public static let teamsBundleID = "com.microsoft.teams2" }`; `build/Xlate.app` launched as `build/Xlate.app/Contents/MacOS/Xlate [--dev <cmd> ...]`.

- [ ] **Step 1:** `Package.swift` with library `XlateCore`, executable `Xlate` (depends on XlateCore), test target `XlateCoreTests`, platform macOS 26 (use `.v26` if the tools version offers it, else `.macOS("26.0")`).
- [ ] **Step 2: Write the failing test**

```swift
@Test func teamsBundleIDIsNewTeams() {
    #expect(TargetApp.teamsBundleID == "com.microsoft.teams2")
}
```

- [ ] **Step 3:** `scripts/test.sh` runs:
  `swift test --build-system native -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F "$@"` with `F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks`. (Plain `swift test` fails on this machine with "no such module 'Testing'"; the default build system fails with "Unknown error parsing property list". Verified 2026-10-16.)
  Run `scripts/test.sh`. Expected: FAIL, `TargetApp` not found.
- [ ] **Step 4:** Add `TargetApp.swift`. Run `scripts/test.sh`. Expected: PASS.
- [ ] **Step 5:** `scripts/make-cert.sh`: generate a self-signed code signing cert `xlate-local` with `openssl` (extendedKeyUsage codeSigning), import the p12 into the login keychain, and set it trusted for code signing. Idempotent: exit 0 if `security find-identity -p codesigning | grep xlate-local` already matches. **The user must run this at the Mac** (keychain prompts). Ask them to run `! scripts/make-cert.sh`.
- [ ] **Step 6:** `Info.plist`: `CFBundleIdentifier dev.ckovacs.xlate`, `CFBundleExecutable Xlate`, `LSUIElement true`, `LSMinimumSystemVersion 26.0`, `NSAudioCaptureUsageDescription "Xlate listens to Microsoft Teams call audio to show live English captions. Audio never leaves this Mac."`. `scripts/bundle.sh`: `swift build -c release --build-system native`, copy binary + plist into `build/Xlate.app`, `codesign --force --options runtime --sign xlate-local build/Xlate.app`.
- [ ] **Step 7:** `main.swift`: if `CommandLine.arguments` contains `--dev`, hand off to `DevCommands` (stub prints usage), else start `NSApplication` with `.accessory` policy and a status item whose only menu item is Quit.
- [ ] **Step 8: Verify**
  `scripts/bundle.sh && plutil -p build/Xlate.app/Contents/Info.plist | grep NSAudioCapture && codesign -dv build/Xlate.app 2>&1 | grep 'Authority=xlate-local'`
  Expected: both greps match.
- [ ] **Step 9: Commit** `Scaffold package, test runner and signed bundle`

### Task 2: Audio process discovery

**Files:**
- Create: `Sources/XlateCore/Audio/AudioProcesses.swift`, `Sources/Xlate/DevCommands.swift`, `Tests/XlateCoreTests/AudioProcessesTests.swift`

**Interfaces:**
- Produces:
  - `public struct AudioProcess: Sendable, Equatable { public let objectID: AudioObjectID; public let pid: pid_t; public let bundleID: String?; public let isRunningOutput: Bool }`
  - `public enum AudioProcesses { public static func all() throws -> [AudioProcess]; public static func matching(_ prefix: String, in list: [AudioProcess]) -> [AudioProcess] }`
  - Dev command `--dev procs` prints one line per process: pid, bundle id, running-output flag.

- [ ] **Step 1: Write the failing test** for the pure filter:

```swift
@Test func matchesTeamsAndHelpers() {
    let list = [
        AudioProcess(objectID: 1, pid: 10, bundleID: "com.microsoft.teams2", isRunningOutput: false),
        AudioProcess(objectID: 2, pid: 11, bundleID: "com.microsoft.teams2.helper", isRunningOutput: true),
        AudioProcess(objectID: 3, pid: 12, bundleID: "com.apple.Music", isRunningOutput: true),
        AudioProcess(objectID: 4, pid: 13, bundleID: nil, isRunningOutput: true),
    ]
    #expect(AudioProcesses.matching("com.microsoft.teams2", in: list).map(\.pid) == [10, 11])
}
```

- [ ] **Step 2:** Run `scripts/test.sh --filter AudioProcessesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. `all()` reads `kAudioHardwarePropertyProcessObjectList` from `kAudioObjectSystemObject`, then per object `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningOutput`. `matching` is a prefix match on bundle ID.
- [ ] **Step 4:** Run tests. Expected: PASS.
- [ ] **Step 5: Verify live:** with Teams open, `build/Xlate.app/Contents/MacOS/Xlate --dev procs | grep teams2`. Expected: at least one line. Record which bundle IDs appear (helpers may use different IDs, adjust the prefix only if evidence says so).
- [ ] **Step 6: Commit** `Add Core Audio process discovery`

### Task 3: Process tap capture, then the capture gate

**Files:**
- Create: `Sources/XlateCore/Audio/AudioChunk.swift`, `Sources/XlateCore/Audio/ProcessTap.swift`, `Tests/XlateCoreTests/ProcessTapTests.swift`
- Modify: `Sources/Xlate/DevCommands.swift`

**Interfaces:**
- Consumes: `AudioProcess`, `AudioProcesses`.
- Produces:
  - `public struct AudioChunk: Sendable { public let samples: [Float]; public let hostTime: UInt64 }` (16 kHz mono)
  - `public final class ProcessTap { public init(processes: [AudioObjectID]) throws; public var chunks: AsyncStream<AudioChunk> { get }; public func stop() }`
  - `public enum Downmix { public static func toMono16k(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> [Float] }`
  - Dev command `--dev tap --seconds N [--wav PATH] [--bundle ID]` prints RMS per second and optionally writes a WAV.

- [ ] **Step 1: Write failing tests** for `Downmix`: a 48 kHz stereo buffer of 4800 frames with L=0.5, R=-0.5 yields 1600 samples, all ≈ 0 (abs < 1e-3); a 48 kHz stereo 1 kHz sine of 0.5 amplitude in both channels yields 1600 samples with RMS ≈ 0.354 (±0.02).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. `CATapDescription(stereoMixdownOfProcesses:)`, `AudioHardwareCreateProcessTap`, private aggregate device (`kAudioAggregateDeviceIsPrivateKey: true`, tap list containing the tap UUID, main sub-device = current default output UID), IOProc via `AudioDeviceCreateIOProcIDWithBlock`, convert with `AVAudioConverter` to 16 kHz mono, yield into the stream. Listen on `kAudioHardwarePropertyDefaultOutputDevice`; on change, destroy and recreate the aggregate device with the new output UID without ending the stream (Review Focus 1).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Device-change test (Review Focus 1):** a test with an injected `OutputDeviceProvider` protocol (`currentUID() -> String`, change callback) asserts that firing a change calls `rebuildAggregate(outputUID:)` once with the new UID and the `chunks` stream is not finished.
- [ ] **Step 6: CAPTURE GATE (needs the user at the Mac).** Ask the user to: run `scripts/bundle.sh`, start Teams' built-in Test call (Settings → Devices → Make a test call), then run `build/Xlate.app/Contents/MacOS/Xlate --dev tap --seconds 25`. First run triggers the system audio capture prompt; the user must allow it.
  Expected: RMS lines clearly above 0.001 while the bot and the playback speak, near 0 otherwise. Also run `--dev procs` during the call to log which PID has `isRunningOutput=1`.
  **If RMS stays ≈ 0 or the tap can't isolate Teams: stop and report to the user before Task 4.** (Known macOS 26 issue: tap IOProc delivers all-zero buffers, Apple forums thread 825780.)
- [ ] **Step 7: Commit** `Capture Teams audio via Core Audio process tap`

### Task 4: Speech gate (VAD + segmentation)

**Files:**
- Create: `Sources/XlateCore/Speech/SpeechGate.swift`, `Tests/XlateCoreTests/SpeechGateTests.swift`

**Interfaces:**
- Consumes: `AudioChunk`.
- Produces: `public struct Utterance: Sendable { public let samples: [Float]; public let duration: TimeInterval }`; `public struct SpeechGate { public init(config: Config = .default); public mutating func push(_ chunk: AudioChunk) -> [Utterance]; public mutating func flush() -> Utterance? }` with `Config.default`: frame 30 ms, start when frame RMS > noise floor × 4 (≈ +12 dB) for 3 consecutive frames, end after 600 ms below threshold, `maxDuration` 12 s, `minDuration` 0.4 s. Noise floor = slow EMA of non-speech frame RMS, initial 0.002.

- [ ] **Step 1: Write failing tests:**
  - `silenceEmitsNothing`: 5 s of zeros → `[]`, `flush() == nil`.
  - `speechBurstEmitsOneUtterance`: 1 s silence, 2 s noise at RMS 0.1, 1 s silence → exactly 1 utterance, duration in 2.0...2.7.
  - `clickIsIgnored`: 1 s silence, 60 ms burst, 1 s silence → `[]`.
  - `longMonologueIsCut` (Review Focus 3): 30 s continuous noise at RMS 0.1 → at least 2 utterances emitted before `flush()`, none longer than 12.0 s.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `Add energy-based speech gate`

### Task 5: Engine spike and decision

**Files:**
- Create: `scripts/make-fixtures.sh`, `Sources/XlateCore/Speech/Transcriber.swift`, `Sources/XlateCore/Speech/AppleTranscriber.swift`, `Sources/XlateCore/Speech/WhisperTranscriber.swift` (one is deleted at the end), `docs/engine-decision.md`, `Tests/XlateCoreTests/TranscriberIntegrationTests.swift`
- Modify: `Package.swift` (temporarily add `argmax-oss-swift`), `Sources/Xlate/DevCommands.swift`

**Interfaces:**
- Consumes: `Utterance`.
- Produces:
  - `public enum SpokenLanguage: Sendable, Equatable { case portuguese, english, unknown }`
  - `public struct Transcript: Sendable, Equatable { public let text: String; public let language: SpokenLanguage; public let duration: TimeInterval }`
  - `public protocol Transcriber: Sendable { func prepare() async throws -> EngineStatus; func transcribe(_ utterance: Utterance) async throws -> Transcript }`
  - `public enum EngineStatus: Sendable, Equatable { case ready, modelMissing(String) }`
  - Dev command `--dev engines <wav>`: runs gate + every compiled transcriber on the file, prints text, language and wall time per utterance.

- [ ] **Step 1:** `make-fixtures.sh` writes to `fixtures/out/` (gitignored), each as 16 kHz mono WAV via `afconvert -f WAVE -d LEF32@16000 -c 1` plus a `.txt` with the expected text and language:
  - `pt_*.wav`: 5 sentences with voice `Luciana`, including "Vamos fazer o deploy depois da sprint review." and "Ainda precisamos confirmar a data do deploy com o cliente."
  - `en_*.wav`: 3 sentences with an `en_US` voice.
  - `switch.wav`: pt, 1 s silence, en, 1 s silence, pt.
  Also download one public pt-BR conversational clip (Common Voice pt or a podcast excerpt), save outside the repo, and note its source in `docs/engine-decision.md`.
- [ ] **Step 2:** Check API availability first: `SpeechTranscriber.supportedLocales` contains `pt-BR` on this Mac (print it from `--dev engines --locales`); `argmax-oss-swift` current release and API (it was renamed from WhisperKit at v1.0.0, 2026-05-01, with breaking changes).
- [ ] **Step 3:** `AppleTranscriber`: two `SpeechTranscriber` instances (pt-BR, en-US) per utterance; pick language by comparing `NLLanguageRecognizer` hypotheses on each output and the transcribers' confidence. `WhisperTranscriber`: argmax-oss-swift with language detection on, multilingual model sized for good pt-BR on M1 Max (try `large-v3-turbo` first).
- [ ] **Step 4: Integration tests**, gated by `XLATE_INTEGRATION=1` (skip otherwise), parameterized over available transcribers:
  - every `pt_*` fixture → `.portuguese`, word error rate vs `.txt` < 20%
  - every `en_*` fixture → `.english`
  - the loanword sentence → `.portuguese` (Review Focus 4 at the engine level)
- [ ] **Step 5:** Run `XLATE_INTEGRATION=1 scripts/test.sh --filter TranscriberIntegration` and `--dev engines` on all fixtures plus the public clip. Record per engine in `docs/engine-decision.md`: pt WER, language accuracy on `switch.wav`, median and p95 seconds per utterance, model size on disk.
- [ ] **Step 6: Decide** using the spec's order: pt-BR accuracy, switching, latency, simplicity; Apple wins if close. Delete the losing transcriber and, if Apple wins, remove the package dependency. Commit the decision doc.
- [ ] **Step 7: Commit** `Pick speech engine from measured spike`

### Task 6: Translator

**Files:**
- Create: `Sources/XlateCore/Translate/Translator.swift`, `Tests/XlateCoreTests/TranslatorIntegrationTests.swift`

**Interfaces:**
- Produces: `public protocol Translator: Sendable { func prepare() async throws -> EngineStatus; func translate(_ portuguese: String) async throws -> String }`; `public final class AppleTranslator: Translator`.

- [ ] **Step 1:** Confirm on Apple's docs which headless `TranslationSession` initializer is available on macOS 26.6 (`init(installedSource:target:)`; the `preferredStrategy:` variant is listed as 26.4+). `prepare()` uses `LanguageAvailability` and returns `.modelMissing("Portuguese → English translation")` unless status is `.installed`. Never trigger a download from `translate`.
- [ ] **Step 2: Write failing integration test** (`XLATE_INTEGRATION=1`): `translate("Ainda precisamos confirmar a data do deploy com o cliente.")` lowercased contains "confirm", "date" and "client".
- [ ] **Step 3:** Run. Expected: FAIL. Implement. Run. Expected: PASS (if `.modelMissing`, ask the user to install the Portuguese language in System Settings → General → Language & Region → Translation Languages, then rerun).
- [ ] **Step 4: Commit** `Add on-device PT to EN translator`

### Task 7: Caption filter and pipeline

**Files:**
- Create: `Sources/XlateCore/Pipeline/CaptionFilter.swift`, `Sources/XlateCore/Pipeline/CaptionPipeline.swift`, `Tests/XlateCoreTests/CaptionPipelineTests.swift`

**Interfaces:**
- Consumes: `AudioChunk`, `SpeechGate`, `Transcriber`, `Translator`, `Transcript`.
- Produces:
  - `public struct Caption: Sendable, Equatable { public let english: String; public let portuguese: String }`
  - `public enum CaptionFilter { public static func accepts(_ t: Transcript) -> Bool }`: true only if `.portuguese`, ≥ 2 words, duration ≥ 0.5 s.
  - `public actor CaptionPipeline { public init(transcriber: any Transcriber, translator: any Translator, gate: SpeechGate = .init()); public func run(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<Caption> }`. Utterances are processed in order; if one is still transcribing when the next arrives, queue at most 1 and drop older queued ones so captions never lag behind by more than one phrase.

- [ ] **Step 1: Write failing tests** with `FakeTranscriber` (returns scripted transcripts) and `FakeTranslator`:
  - `englishIsDropped`: `.english` transcript → no caption.
  - `shortJunkIsDropped`: `.portuguese`, text "é", 0.3 s → no caption (chime/hum case).
  - `portugueseIsTranslated`: produces `Caption(english: "fake:<pt>", portuguese: <pt>)`.
  - `translatorErrorDropsOnlyThatCaption`: translator throws on the first, succeeds on the second → exactly one caption, pipeline still running.
  - `backlogKeepsNewest`: transcriber delays 2 s, five utterances arrive in 1 s → captions emitted for the first and the last only.
  - `loanwordSentenceIsPortuguese` (Review Focus 4): with the real chosen transcriber, behind `XLATE_INTEGRATION=1`, the loanword fixture produces a caption.
- [ ] **Step 2:** Run. Expected: FAIL. Implement. Run. Expected: PASS.
- [ ] **Step 3: Commit** `Add caption filter and pipeline`

### Task 8: Wake monitor

**Files:**
- Create: `Sources/XlateCore/Wake/WakeMonitor.swift`, `Tests/XlateCoreTests/WakeMonitorTests.swift`

**Interfaces:**
- Consumes: `AudioProcesses`, `TargetApp`.
- Produces:
  - `public enum WakeState: Equatable { case waitingForTarget, idle, active(Set<AudioObjectID>) }`
  - `public struct WakeMachine { public mutating func observe(_ procs: [AudioProcess], at time: TimeInterval) -> WakeState }`: `.active` once any target process has had running output for ≥ 1 s; back to `.idle` after 30 s with no target output; `.waitingForTarget` when no target process exists. When the set of outputting target object IDs changes while active, return `.active(newSet)`.
  - `public final class WakeMonitor { public init(bundlePrefix: String, interval: TimeInterval = 1); public var states: AsyncStream<WakeState> { get } }` polls `AudioProcesses.all()`.

- [ ] **Step 1: Write failing tests** on `WakeMachine` with explicit timestamps:
  - no Teams → `.waitingForTarget`
  - Teams present, not outputting → `.idle`
  - outputting at t=0 and t=0.5 → still `.idle`; at t=1.0 → `.active([2])`
  - active, output stops at t=10, at t=39 still active, at t=40 `.idle`
  - `pidChangeReattaches` (Review Focus 2): active with object 2, next observation has object 7 outputting and 2 gone → `.active([7])`
- [ ] **Step 2:** Run. Expected: FAIL. Implement. Run. Expected: PASS.
- [ ] **Step 3: Commit** `Add Teams wake monitor`

### Task 9: Pill panel

**Files:**
- Create: `Sources/XlateCore/UI/PillTiming.swift`, `Sources/Xlate/PillPanel.swift`, `Tests/XlateCoreTests/PillTimingTests.swift`
- Modify: `Sources/Xlate/DevCommands.swift`

**Interfaces:**
- Consumes: `Caption`.
- Produces:
  - `public struct PillTiming { public static let fadeAfter: TimeInterval = 8; public static func isVisible(lastCaptionAt: TimeInterval?, now: TimeInterval) -> Bool }`
  - `public enum PillPlacement { public static func clamp(origin: CGPoint, size: CGSize, visibleFrames: [CGRect], preferred: CGRect) -> CGPoint; public static func defaultOrigin(size: CGSize, in screen: CGRect) -> CGPoint }`. Default is horizontally centered, top edge 60 pt below the top of the visible frame.
  - `@MainActor final class PillPanel: NSPanel { func show(_ caption: Caption); func resetPosition() }`
  - Dev command `--dev pill-demo`: shows a sample caption for 10 s.

- [ ] **Step 1: Write failing tests:**
  - `hiddenWithoutCaption`, `visibleAt7_9s`, `hiddenAt8_0s`.
  - `offscreenOriginClamps` (Review Focus 5): origin (5000, 5000) with one visible frame (0,0,1512,945) → result keeps the pill fully inside that frame.
  - `onscreenOriginUnchanged`.
- [ ] **Step 2:** Run. Expected: FAIL. Implement `PillTiming`/`PillPlacement`. Run. Expected: PASS.
- [ ] **Step 3:** `PillPanel`: `styleMask [.nonactivatingPanel, .borderless]`, `level .statusBar`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `isMovableByWindowBackground = true`, `becomesKeyOnlyIfNeeded = true`, `canBecomeKey` false. SwiftUI `PillView` per Global Constraints. Save origin to `pillOrigin` on move; restore through `clamp`.
- [ ] **Step 4: Verify:** `--dev pill-demo &; sleep 2; screencapture -x /private/tmp/pill.png`, send the screenshot to the user, and confirm it matches option C of the mockup. Then check with the user that clicking the pill during a Teams call doesn't take focus from Teams.
- [ ] **Step 5: Commit** `Add floating caption pill`

### Task 10: App wiring, menu, login item, end-to-end

**Files:**
- Create: `Sources/Xlate/AppDelegate.swift`
- Modify: `Sources/Xlate/main.swift`, `Sources/Xlate/DevCommands.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: the shipped app. Dev command `--dev play-target <bundleID>`: runs the full app wiring against a different target bundle (for QuickTime: `com.apple.QuickTimePlayerX`).

- [ ] **Step 1:** `AppDelegate`: status item menu with a disabled status line (`Waiting for Teams` / `Idle` / `Listening` / `Speech model missing` / `Translation model missing`), `Enabled` toggle (persisted), `Reset pill position`, `Open at login` toggle via `SMAppService.mainApp`, `Set up models…` (the only action allowed to download), `Quit`. On `.active(ids)`: create `ProcessTap(ids)`, run `CaptionPipeline`, send captions to `PillPanel`. On `.idle`/`.waitingForTarget`: stop tap, hide pill. If either engine's `prepare()` returns `.modelMissing`, show status and never start the tap (fail closed).
- [ ] **Step 2:** `XLATE_DEBUG_AUDIO_DIR`: when set, write each utterance as WAV there; when unset, nothing touches disk. Grep check: `grep -rn 'print(\|os_log\|Logger' Sources/XlateCore Sources/Xlate/AppDelegate.swift` shows no call that includes caption, transcript or translation text.
- [ ] **Step 3: End-to-end without Teams:** `scripts/bundle.sh`, open QuickTime with `fixtures/out/switch.wav`, run `--dev play-target com.apple.QuickTimePlayerX`, press play. Expected: pill shows the two Portuguese sentences in English with Portuguese beneath, nothing during the English sentence, fades 8 s after the end. Screenshot to the user.
- [ ] **Step 4: Network check:** during step 3, `nettop -P -L 1 -p $(pgrep -x Xlate)` shows zero bytes in/out.
- [ ] **Step 5: Disk check:** `find ~ -newer build/Xlate.app -name '*.wav' -o -newer build/Xlate.app -name '*.caf' 2>/dev/null | grep -v fixtures` returns nothing after a run without `XLATE_DEBUG_AUDIO_DIR`.
- [ ] **Step 6: User acceptance (needs the user):** install via `cp -R build/Xlate.app /Applications/`, enable "Open at login", join a real Teams call with Portuguese speakers. Check against the spec's "Done means" list, including that ringtones and join chimes don't show the pill.
- [ ] **Step 7: Commit** `Wire menu bar app, wake monitor and pill`
