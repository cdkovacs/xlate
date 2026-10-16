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
    private let lock = NSLock()
    private var downmix: Downmix?
    private var existingFormat: AVAudioFormat?

    public convenience init(processes: [AudioObjectID]) throws {
        try self.init(backend: HALTapBackend(processes: processes), outputs: SystemOutputDevice())
    }

    init(backend: TapBackend, outputs: OutputDeviceProvider) throws {
        (chunks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.backend = backend
        self.outputs = outputs
        try start()
        outputs.onChange = { [weak self] in self?.rebuild() }
    }

    public func stop() {
        outputs.onChange = nil
        backend.stop()
        continuation.finish()
    }

    private func start() throws {
        try backend.start(outputUID: outputs.currentUID()) { [weak self] buffer in
            self?.deliver(buffer)
        }
    }

    private func rebuild() {
        backend.stop()
        do { try start() } catch { stop() }
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
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "xlate.tap", qos: .userInitiated)

    init(processes: [AudioObjectID]) {
        self.processes = processes
    }

    func start(outputUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
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
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
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
