import AVFoundation
import CoreAudio
import Foundation

/// The HAL work behind a tap: create the tap and an aggregate device on the
/// given output, and deliver buffers until stopped.
public protocol TapBackend: AnyObject {
    func start(outputUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// The system default output device, and a hook for when it changes.
public protocol OutputDeviceProvider: AnyObject {
    func currentUID() throws -> String
    var onChange: (() -> Void)? { get set }
}

/// Captures what a set of processes plays, as 16 kHz mono chunks. Survives
/// output device changes (AirPods connecting) by rebuilding the aggregate
/// device without ending the stream.
public final class ProcessTap: @unchecked Sendable {
    public let chunks: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let backend: TapBackend
    private let outputs: OutputDeviceProvider
    private let retryDelays: [Duration]
    /// Guards backend start/stop. Device changes arrive on the output-device
    /// queue while stop() comes from the main thread.
    private let lifecycle = NSLock()
    private var stopped = false
    /// Guards the converter, used from the IOProc queue.
    private let lock = NSLock()
    private var downmix: Downmix?
    private var existingFormat: AVAudioFormat?

    /// `muted` silences the tapped processes on the speakers (dev playback only).
    public convenience init(processes: [AudioObjectID], muted: Bool = false) throws {
        try self.init(backend: HALTapBackend(processes: processes, muted: muted), outputs: SystemOutputDevice())
    }

    /// `retryDelays`: waits between rebuild attempts after a device change.
    /// Bluetooth devices often aren't ready when the change notification fires.
    init(backend: TapBackend, outputs: OutputDeviceProvider,
         retryDelays: [Duration] = [.milliseconds(300), .seconds(1)]) throws {
        (chunks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.backend = backend
        self.outputs = outputs
        self.retryDelays = retryDelays
        try start()
        outputs.onChange = { [weak self] in self?.rebuild() }
    }

    /// Ends the stream. Consumers treat an end they didn't ask for as a lost tap.
    public func stop() {
        lifecycle.lock()
        guard !stopped else { return lifecycle.unlock() }
        stopped = true
        outputs.onChange = nil
        backend.stop()
        lifecycle.unlock()
        continuation.finish()
    }

    private func start() throws {
        try backend.start(outputUID: outputs.currentUID()) { [weak self] buffer in
            self?.deliver(buffer)
        }
    }

    private func rebuild() {
        for attempt in 0...retryDelays.count {
            lifecycle.lock()
            if stopped { return lifecycle.unlock() }
            backend.stop()
            do {
                try start()
                return lifecycle.unlock()
            } catch {
                lifecycle.unlock()
            }
            if attempt < retryDelays.count {
                let delay = retryDelays[attempt].components
                Thread.sleep(forTimeInterval: Double(delay.seconds) + Double(delay.attoseconds) / 1e18)
            }
        }
        stop()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let converter: Downmix
        if let existing = downmix, existingFormat == buffer.format {
            converter = existing
        } else {
            converter = Downmix(input: buffer.format)
            downmix = converter
            existingFormat = buffer.format
        }
        let samples = converter.toMono16k(buffer)
        lock.unlock()
        if !samples.isEmpty {
            continuation.yield(AudioChunk(samples: samples, hostTime: mach_absolute_time()))
        }
    }

}

/// Real backend: CATapDescription → process tap → private aggregate device → IOProc.
final class HALTapBackend: TapBackend {
    private let processes: [AudioObjectID]
    private let muted: Bool
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "xlate.tap", qos: .userInitiated)

    init(processes: [AudioObjectID], muted: Bool) {
        self.processes = processes
        self.muted = muted
    }

    func start(outputUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = muted ? .muted : .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd: AudioStreamBasicDescription = try CoreAudioProperty.scalar(tapID, kAudioTapPropertyFormat)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError(status: -1, what: "tap format")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Xlate Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create aggregate device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = TapBuffers.pcmBuffer(from: input, format: format) else { return }
            onBuffer(buffer)
        }, "create IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            stop()
            throw CoreAudioError(status: status, what: what)
        }
    }
}

public enum TapBuffers {
    /// The last buffers of an aggregate's input list that add up to the tap's
    /// channel count, or nil if they don't line up.
    public static func trailing(_ list: UnsafeMutableAudioBufferListPointer, channels: Int) -> [AudioBuffer]? {
        var picked: [AudioBuffer] = []
        var total = 0
        for buffer in list.reversed() where total < channels {
            picked.insert(buffer, at: 0)
            total += Int(buffer.mNumberChannels)
        }
        return total == channels ? picked : nil
    }

    /// Wraps the tap's part of an aggregate input list without copying samples.
    /// Input streams of the output device (a headset's mic) come before the
    /// tap's, so the tap's buffers are taken from the end.
    public static func pcmBuffer(from input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let picked = trailing(all, channels: Int(format.channelCount)) else { return nil }
        if picked.count == all.count {
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
        }
        // AVAudioPCMBuffer copies the list struct (not the samples), so this
        // temporary list can go as soon as the buffer exists.
        let list = AudioBufferList.allocate(maximumBuffers: picked.count)
        defer { free(list.unsafeMutablePointer) }
        for (i, buffer) in picked.enumerated() { list[i] = buffer }
        return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil)
    }
}

final class SystemOutputDevice: OutputDeviceProvider {
    var onChange: (() -> Void)?
    private var address = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
    private let queue = DispatchQueue(label: "xlate.output-device")
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }

    func currentUID() throws -> String {
        let device: AudioObjectID = try CoreAudioProperty.scalar(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return try CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID)
    }
}
