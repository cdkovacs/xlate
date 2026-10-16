import CoreAudio
import Foundation

/// One process Core Audio knows about, as reported by the HAL.
public struct AudioProcess: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public enum AudioProcesses {
    /// Every process currently registered with Core Audio.
    public static func all() throws -> [AudioProcess] {
        let ids: [AudioObjectID] = try CoreAudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return ids.compactMap { id in
            guard let pid: pid_t = try? CoreAudioProperty.scalar(id, kAudioProcessPropertyPID) else { return nil }
            let bundle: String? = try? CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)
            let running: UInt32 = (try? CoreAudioProperty.scalar(id, kAudioProcessPropertyIsRunningOutput)) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle?.isEmpty == true ? nil : bundle,
                                isRunningOutput: running != 0)
        }
    }

    /// Processes whose bundle ID starts with `prefix`. Teams helpers carry the
    /// main app's bundle ID as a prefix.
    public static func matching(_ prefix: String, in list: [AudioProcess]) -> [AudioProcess] {
        list.filter { $0.bundleID?.hasPrefix(prefix) == true }
    }
}

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String
    public var description: String { "\(what) failed (OSStatus \(status))" }
}

/// Thin typed wrappers over AudioObjectGetPropertyData for global-scope properties.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, value)
        guard status == noErr else { throw CoreAudioError(status: status, what: "get \(selector)") }
        return value.load(as: T.self)
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, what: "size \(selector)") }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer)
        guard status == noErr else { throw CoreAudioError(status: status, what: "get \(selector)") }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { throw CoreAudioError(status: status, what: "get \(selector)") }
        return value.takeRetainedValue() as String
    }
}
