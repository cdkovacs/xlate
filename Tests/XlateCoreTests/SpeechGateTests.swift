import Foundation
import Testing
@testable import XlateCore

/// Deterministic white noise with the given RMS (uniform in ±rms·√3).
private func noise(seconds: Double, rms: Float, seed: UInt64 = 42) -> [Float] {
    var state = seed
    let amplitude = rms * 3.0.squareRoot().asFloat
    return (0..<Int(seconds * AudioChunk.sampleRate)).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * amplitude
    }
}

/// Speech-like signal: noise whose loudness swings between 30% and 100% of
/// `peak` at syllable rate (4 Hz), so it never goes quiet for long.
private func speech(seconds: Double, peak: Float, seed: UInt64 = 7) -> [Float] {
    let carrier = noise(seconds: seconds, rms: peak, seed: seed)
    return carrier.enumerated().map { i, x in
        let phase = 2 * Float.pi * 4 * Float(i) / Float(AudioChunk.sampleRate)
        return x * (0.65 + 0.35 * sin(phase))
    }
}

private func silence(seconds: Double) -> [Float] {
    Array(repeating: 0, count: Int(seconds * AudioChunk.sampleRate))
}

/// Feeds samples in 100 ms chunks, the way the tap delivers them.
private func run(_ samples: [Float], gate: inout SpeechGate) -> [Utterance] {
    stride(from: 0, to: samples.count, by: 1600).flatMap { start in
        gate.push(AudioChunk(samples: Array(samples[start..<min(start + 1600, samples.count)]), hostTime: 0))
    }
}

private extension Double { var asFloat: Float { Float(self) } }

@Test func silenceEmitsNothing() {
    var gate = SpeechGate()
    #expect(run(silence(seconds: 5), gate: &gate).isEmpty)
    #expect(gate.flush() == nil)
}

@Test func speechBurstEmitsOneUtterance() {
    var gate = SpeechGate()
    let out = run(silence(seconds: 1) + noise(seconds: 2, rms: 0.1) + silence(seconds: 1), gate: &gate)
    #expect(out.count == 1)
    #expect((2.0...2.7).contains(out.first?.duration ?? 0), "duration \(out.first?.duration ?? 0)")
}

@Test func clickIsIgnored() {
    var gate = SpeechGate()
    let out = run(silence(seconds: 1) + noise(seconds: 0.06, rms: 0.1) + silence(seconds: 1), gate: &gate)
    #expect(out.isEmpty)
    #expect(gate.flush() == nil)
}

@Test func longMonologueIsCut() {
    var gate = SpeechGate()
    let out = run(speech(seconds: 30, peak: 0.1), gate: &gate)
    #expect(out.count >= 2)
    #expect(out.allSatisfy { $0.duration <= 10.0 })
}

@Test func pausesAreFoundOverBackgroundHiss() {
    // Measured on a real pt-BR recording: hiss ≈ 0.009 RMS, speech only
    // ≈ 6 dB above it, and speech from the very first frame.
    var gate = SpeechGate()
    let hiss = noise(seconds: 8, rms: 0.009, seed: 99)
    var mix = speech(seconds: 3, peak: 0.035) + Array(repeating: 0, count: 16_000) + speech(seconds: 3, peak: 0.035, seed: 8)
    mix += Array(repeating: 0, count: hiss.count - mix.count)
    let out = run(zip(mix, hiss).map(+), gate: &gate) + [gate.flush()].compactMap { $0 }
    #expect(out.count == 2, "durations \(out.map(\.duration))")
    #expect(out.allSatisfy { $0.duration < 5 })
}

@Test func phraseBreakEndsLongUtterance() {
    // Narration pauses ~250 ms between phrases; after 4 s that should cut.
    var gate = SpeechGate()
    let pause = [Float](repeating: 0, count: 4_000)
    let out = run(silence(seconds: 1) + speech(seconds: 5, peak: 0.1) + pause + speech(seconds: 3, peak: 0.1, seed: 8)
                  + silence(seconds: 1), gate: &gate)
    #expect(out.count == 2, "durations \(out.map(\.duration))")
    #expect((5.0...5.6).contains(out.first?.duration ?? 0))
}

@Test func shortPauseEarlyDoesNotSplit() {
    var gate = SpeechGate()
    let pause = [Float](repeating: 0, count: 4_000)
    let out = run(silence(seconds: 1) + speech(seconds: 2, peak: 0.1) + pause + speech(seconds: 2, peak: 0.1, seed: 8)
                  + silence(seconds: 1), gate: &gate)
    #expect(out.count == 1, "durations \(out.map(\.duration))")
}

@Test func hardCapIsTenSeconds() {
    var gate = SpeechGate()
    let out = run(speech(seconds: 30, peak: 0.1), gate: &gate)
    #expect(out.allSatisfy { $0.duration <= 10.0 })
    #expect(out.count >= 2)
}
