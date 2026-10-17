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

private struct FakeStartError: Error {}

private final class FakeBackend: TapBackend {
    var startedWith: [String] = []
    var stops = 0
    /// Indices of start() calls that should throw (0 = the initial start).
    var failing: Set<Int> = []
    func start(outputUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        startedWith.append(outputUID)
        if failing.contains(startedWith.count - 1) { throw FakeStartError() }
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

@Test func rebuildRetriesTransientFailure() async throws {
    let backend = FakeBackend()
    backend.failing = [1, 2]
    let outputs = FakeOutputs()
    let tap = try ProcessTap(backend: backend, outputs: outputs, retryDelays: [.zero, .zero])
    let finished = Mutex(false)
    let watcher = Task { [tap] in
        for await _ in tap.chunks {}
        finished.withLock { $0 = true }
    }
    outputs.uid = "airpods"
    outputs.onChange?()
    #expect(backend.startedWith == ["built-in", "airpods", "airpods", "airpods"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(finished.withLock { $0 } == false)
    tap.stop()
    _ = await watcher.value
}

@Test func rebuildGivesUpAndEndsStream() async throws {
    let backend = FakeBackend()
    backend.failing = [1, 2, 3]
    let outputs = FakeOutputs()
    let tap = try ProcessTap(backend: backend, outputs: outputs, retryDelays: [.zero, .zero])
    let watcher = Task { [tap] in
        for await _ in tap.chunks {}
        return true
    }
    outputs.onChange?()
    #expect(await watcher.value == true)
    #expect(backend.startedWith.count == 4)
}

@Test func deviceChangeAfterStopDoesNothing() throws {
    let backend = FakeBackend()
    let outputs = FakeOutputs()
    let tap = try ProcessTap(backend: backend, outputs: outputs)
    let change = outputs.onChange
    tap.stop()
    change?()
    #expect(backend.startedWith == ["built-in"])
}

@Test func tapBuffersAreTakenFromTheEnd() {
    // A headset as default output puts its mic streams ahead of the tap's.
    var mic: Float = 0, left: Float = 0, right: Float = 0
    let list = AudioBufferList.allocate(maximumBuffers: 3)
    defer { free(list.unsafeMutablePointer) }
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: &mic)
    list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: &left)
    list[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: &right)
    let picked = TapBuffers.trailing(list, channels: 2)
    #expect(picked?.map(\.mData) == [list[1].mData, list[2].mData])
}

@Test func interleavedTapBufferIsTakenFromTheEnd() {
    var mic: Float = 0, stereo: (Float, Float) = (0, 0)
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: &mic)
    list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: &stereo)
    #expect(TapBuffers.trailing(list, channels: 2)?.map(\.mData) == [list[1].mData])
}

@Test func mismatchedChannelsGiveNothing() {
    var mono: Float = 0
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: &mono)
    #expect(TapBuffers.trailing(list, channels: 2) == nil)
}

@Test func pcmBufferFromAggregateDropsMicAndOutlivesTheList() {
    // Mic (1 ch) ahead of an interleaved stereo tap buffer, as with a headset.
    var mic = [Float](repeating: 9, count: 4)
    var stereo: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    let list = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(list.unsafeMutablePointer) }
    mic.withUnsafeMutableBytes { list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: $0.baseAddress) }
    stereo.withUnsafeMutableBytes { list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: $0.baseAddress) }
    var buffer = TapBuffers.pcmBuffer(from: list.unsafePointer, format: format)
    #expect(buffer?.frameLength == 4)
    #expect(buffer?.audioBufferList.pointee.mBuffers.mData == list[1].mData)
    buffer = nil  // deallocating must not free memory it doesn't own
}

@Test func pcmBufferUsesWholeListWhenItIsAllTap() {
    var stereo: [Float] = [0.1, -0.1, 0.2, -0.2]
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    stereo.withUnsafeMutableBytes { list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: $0.baseAddress) }
    #expect(TapBuffers.pcmBuffer(from: list.unsafePointer, format: format)?.frameLength == 2)
}
