# Speech engine decision (Task 5)

Date: 2026-10-16. Machine: M1 Max (MacBookPro18,2), 32 GB, macOS 26.6.

**Picked: Whisper** (`openai_whisper-large-v3-v20240930_626MB` via
argmax-oss-swift 1.1.1, Neural Engine default compute).

## Test material

- Synthetic: `scripts/make-fixtures.sh` (Luciana pt-BR, Samantha en-US),
  5 Portuguese sentences, 3 English, and `switch.wav` (pt / en / pt).
- Real speech: first 60 s of
  [Pt-Brasil_intro.ogg](https://commons.wikimedia.org/wiki/File:Pt-Brasil_intro.ogg)
  (Wikimedia Commons, CC BY-SA), a Brazilian speaker reading the Brasil
  article intro. Steady hiss about 6 dB under the speech.

Both engines got the same utterances from `SpeechGate`.

## Results

| | Apple SpeechTranscriber (pt-BR + en-US in parallel) | Whisper large-v3-turbo |
|---|---|---|
| Synthetic pt, WER < 20% | 5/5 | 5/5 |
| Language on `switch.wav` | 3/3 | 3/3 |
| Loanword sentence ("deploy", "sprint review") → pt | yes | yes |
| Real clip, meaning-changing errors in 7 utterances | 4 ("Noruega" for noroeste, "ganhado" for banhado, "Diana Francesa", "Srinami") | 0 |
| ASR time per utterance, median / p95 | 0.32 s / 0.65 s | 1.51 s / 1.60 s |
| Extra disk | none (system models) | 608 MB |

Whisper timing is after collapsing language detection into the transcribe
pass (separate detection was 2.45 s). GPU encoder compute gave no gain
(1.45 s median) and a slow first run, so it stays on the Neural Engine.

## Why

The spec ranks Brazilian Portuguese accuracy first and prefers Apple only
if close. It isn't close on real speech: Apple's errors change place names
and directions, Whisper made none. Whisper's 1.5 s plus translation stays
inside the 3 s target.

## Gotchas found

- WhisperKit's `detectLangauge` returns only the chosen language's
  log-prob in `langProbs`, not a distribution. Use the returned code.
- Pinning `language: "en"` on Portuguese audio makes Whisper translate
  rather than transcribe, so a wrong language guess is very visible.
