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
    let out = run(noise(seconds: 30, rms: 0.1), gate: &gate)
    #expect(out.count >= 2)
    #expect(out.allSatisfy { $0.duration <= 12.0 })
}
