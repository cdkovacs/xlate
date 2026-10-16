# Teams PT-BR → English live captions (xlate)

Date: 2026-10-16
Status: draft for review

## Intent

The user joins Microsoft Teams calls where colleagues speak Brazilian
Portuguese and switch to English mid-call. They listen to the call normally
and want English captions in a small floating window so they can follow
along without looking away. Everything must run on their Mac. No call audio
or text leaves the machine, and nothing is saved.

Target machine: Apple M1 Max, 32 GB RAM, macOS 26.6. Swift 6.4 command line
toolchain is installed. Full Xcode was not detected (builder's call whether
to install it).

## Goals

- Capture only the audio Teams plays out (the remote participants). Not the
  user's mic, not other apps.
- Transcribe Portuguese speech and translate it to English, on-device.
- Handle code-switching: when a speaker uses English, show it as-is with no
  translation line.
- Show captions in a floating "pill" overlay (see Overlay below).
- Start automatically. The app lives in the menu bar, launches at login,
  wakes when Teams is producing audio, and stays hidden otherwise.
- Target latency: English text visible within roughly 1 to 3 seconds of the
  end of a phrase.

## Non-goals

- No transcript, history, export, or logging of call content. Captions
  disappear when replaced and when the call ends.
- No speaker names or diarization.
- No translation of the user's own voice.
- No distribution: built and run on this one Mac. No App Store, no
  notarization, no installer.
- No support for other meeting apps in v1 (Zoom, Meet, browser Teams).
  Design the capture layer so the target app's bundle ID is a constant, but
  don't build a picker.

## Anti-goals (failure even if it "works")

- Any network call carrying audio or text. Downloading models/language packs
  once at setup is fine; runtime traffic is not.
- Writing call audio or text to disk, including debug logs, crash dumps with
  transcript content, or temp WAV files left behind. Debug audio dumps are OK
  only behind an explicit developer flag that's off by default.
- The pill popping up for Teams ringtones, join/leave chimes, or silence.
- The overlay stealing focus or keystrokes from Teams.

## Overlay (decided with the user)

The user picked the "floating pill" from three mockups. Mockup image:
`/private/tmp/claude-501/-Users-ckovacs-git-xlate/b3f3ade7-1538-47bd-a953-b39243741b32/scratchpad/mockups.png`
(option C; temp location, may be gone).

- Rounded dark translucent panel, about 400 pt wide, centered near the top of
  the screen by default.
- Line 1: English, about 15 pt, white. Line 2: original Portuguese, about
  12 pt, italic, muted grey. For English speech, line 2 is omitted.
- Small green dot indicates it's live.
- Shows the current sentence only. A new finished sentence replaces the old
  one. Wraps to more lines if the sentence is long rather than truncating.
- Draggable anywhere; remembers its position across launches (position only,
  never content).
- Always on top, including over full-screen Teams and across Spaces.
  Non-activating: clicking or dragging it must not take focus from Teams.
- Fades out after a few seconds with no new speech (builder picks the exact
  timeout, something like 6 to 10 s).

## Behavior

1. Menu bar app (no Dock icon), launch-at-login. Menu has: enable/disable,
   reset pill position, quit, and a status line (e.g. "Waiting for Teams",
   "Listening", "Portuguese model missing").
2. Watches for the Teams process (new Teams bundle ID; builder confirms it,
   currently believed to be `com.microsoft.teams2`) and whether it is
   producing output audio.
3. When Teams starts producing audio, attach a Core Audio process tap
   (macOS 14.2+ `AudioHardwareCreateProcessTap` / `CATapDescription`) to the
   Teams process(es). Teams may play audio from a helper process; the tap must
   cover whichever process actually outputs call audio.
4. Voice activity detection gates everything downstream so chimes and
   silence don't produce captions.
5. Speech → text, with per-phrase language identification (pt-BR vs en).
6. Portuguese phrases → on-device English translation. English phrases pass
   through.
7. Push the result to the pill.
8. When Teams stops producing audio for a while, tear down the tap and go
   idle.

## Engine choice (left to the builder, with a required spike)

Two candidate stacks. The builder runs a short spike first and picks one
based on measured results on this Mac.

- **Apple stack:** `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26) for
  speech-to-text, and the `Translation` framework's `TranslationSession` for
  PT→EN. Open questions the spike must answer: is `pt-BR` in
  `SpeechTranscriber.supportedLocales` on this machine; how to handle
  language switching given the transcriber is locale-bound (for example two
  transcribers in parallel plus `NLLanguageRecognizer` on the output, or
  something better); whether `TranslationSession` can be created without a
  SwiftUI view on macOS 26.6 (`init(installedSource:target:)` exists, but
  check its availability).
- **Whisper stack:** WhisperKit, now published as `argmax-oss-swift`
  (v1.0.0 released 2026-05-01, with breaking API changes from earlier
  WhisperKit). Whisper does language ID per segment, which suits
  code-switching. Translation could still use Apple's `TranslationSession`,
  or Whisper's own translate task. Spike must measure latency on M1 Max with
  a model that gives good pt-BR accuracy.

Pick criteria, in order: Brazilian Portuguese accuracy, correct handling of
mid-call language switches, latency, then simplicity. Apple's stack is
preferred if it's close, since it avoids bundling models.

Verify every API and package version against current docs at build time;
the notes above were checked on 2026-10-16 but should not be trusted blindly.

## Constraints

- Swift, native macOS app (AppKit or SwiftUI, builder's call). macOS 26
  minimum is fine since it only runs on this Mac.
- Needs a proper `.app` bundle with `Info.plist` including
  `NSAudioCaptureUsageDescription`, or macOS won't grant audio capture
  permission. One reported pitfall: Xcode's `INFOPLIST_KEY_*` setting for
  this key can be dropped silently; verify the key is in the built plist.
- Ad-hoc / local code signing is fine. Signing identity must stay stable
  between rebuilds, or macOS will re-prompt for permissions each build.
- The user often works remotely over Claude Code, so the build and the
  spike should be runnable from the command line, and a way to test without
  a live Teams call is needed (for example, a dev mode that taps a different
  app like QuickTime playing a pt-BR recording).

## Done means

- With Teams in a call where someone speaks Portuguese, the pill appears on
  its own and shows English plus Portuguese within about 3 s of each phrase.
- When someone switches to English, the pill shows their English with no
  second line, and doesn't show a nonsense "translation".
- Teams ringtones and chimes don't trigger the pill.
- Nothing about the call exists on disk after the call.
- No network traffic at runtime (spot-check with Little Snitch or `nettop`).

## Calls made after review (Claude's calls, not the user's)

- **Capture spike goes first**, ahead of the engine spike. Tap Teams during
  a Teams test call, log which PIDs actually emit call audio, and confirm
  the bundle ID. If per-process tapping can't isolate call audio, stop and
  come back to the user before building anything else.
- **Chimes and ringtones:** VAD alone isn't enough since they come from
  Teams too. The pill only appears once the speech engine returns real
  words (minimum duration and word count, builder tunes). Bar is "rare",
  not zero; one stray pill per call is acceptable, one per chime is not.
- **Code-switching granularity:** sentence-level switching is required.
  English loanwords inside Portuguese sentences ("deploy", "pipeline",
  "sprint") are common in Brazilian tech talk and must come through
  readable. Full intra-sentence switching (half a sentence in each language)
  is best-effort.
- **Test material:** builder assembles pt-BR clips from public sources
  (podcasts, Common Voice) plus synthetic code-switch clips via macOS `say`
  with a pt-BR voice mixed with an English voice. Final acceptance is a real
  Teams call run by the user.
- **Network:** models and language packs download once during setup. At
  runtime, if a model is missing the app shows "model missing" in the menu
  and does nothing (fails closed). Verify with `nettop` during a test call.
- **Build tooling:** SwiftPM plus a script that assembles and signs the
  `.app` bundle, so it builds over the command line without Xcode. Create a
  local self-signed code signing certificate once and reuse it so TCC
  permissions survive rebuilds.

## Left to the builder

UI framework, VAD method, exact fade timing, segmentation strategy, project
layout, test approach, how the pill handles very long monologues, and the
engine choice per the spike criteria above.
