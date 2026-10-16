import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import XlateCore

private func stereoBuffer(frames: Int, left: (Int) -> Float, right: (Int) -> Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        buffer.floatChannelData![0][i] = left(i)
        buffer.floatChannelData![1][i] = right(i)
    }
    return buffer
}

private func rms(_ s: ArraySlice<Float>) -> Float {
    (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
}

@Test func oppositeChannelsCancelToSilence() {
    let buffer = stereoBuffer(frames: 4800, left: { _ in 0.5 }, right: { _ in -0.5 })
    let downmix = Downmix(input: buffer.format)
    let out = (0..<10).flatMap { _ in downmix.toMono16k(buffer) }
    #expect(out.allSatisfy { abs($0) < 1e-3 })
}

@Test func streamingKeepsSampleCount() {
    // The converter works in 4096-frame blocks and carries the remainder to
    // the next call, so count over a stream rather than one buffer.
    let buffer = stereoBuffer(frames: 4800, left: { _ in 0.1 }, right: { _ in 0.1 })
    let downmix = Downmix(input: buffer.format)
    let total = (0..<10).reduce(0) { sum, _ in sum + downmix.toMono16k(buffer).count }
    #expect(abs(total - 16_000) <= 1400, "got \(total)")
}

@Test func sineKeepsItsLevel() {
    let sine: (Int) -> Float = { 0.5 * sin(2 * .pi * 1000 * Float($0) / 48_000) }
    let buffer = stereoBuffer(frames: 4800, left: sine, right: sine)
    let downmix = Downmix(input: buffer.format)
    let out = (0..<10).flatMap { _ in downmix.toMono16k(buffer) }
    // Skip the resampler's filter warm-up at the start.
    #expect(abs(rms(out[200...]) - 0.354) < 0.02)
}

private final class FakeBackend: TapBackend {
    var startedWith: [String] = []
    var stops = 0
    func start(outputUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        startedWith.append(outputUID)
    }
    func stop() { stops += 1 }
}

private final class FakeOutputs: OutputDeviceProvider {
    var uid = "built-in"
    var onChange: (() -> Void)?
    func currentUID() throws -> String { uid }
}

@Test func outputDeviceChangeRebuildsWithoutEndingStream() async throws {
    let backend = FakeBackend()
    let outputs = FakeOutputs()
    let tap = try ProcessTap(backend: backend, outputs: outputs)
    let finished = Mutex(false)
    let watcher = Task { [tap] in
        for await _ in tap.chunks {}
        finished.withLock { $0 = true }
    }
    outputs.uid = "airpods"
    outputs.onChange?()
    #expect(backend.startedWith == ["built-in", "airpods"])
    #expect(backend.stops == 1)
    try await Task.sleep(for: .milliseconds(50))
    #expect(finished.withLock { $0 } == false)
    tap.stop()
    _ = await watcher.value
    #expect(finished.withLock { $0 } == true)
}
