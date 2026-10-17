import AVFoundation

/// A slice of captured audio, already converted to the pipeline format.
public struct AudioChunk: Sendable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]
    public let hostTime: UInt64

    public init(samples: [Float], hostTime: UInt64) {
        self.samples = samples
        self.hostTime = hostTime
    }
}

/// Converts tap buffers (usually 48 kHz stereo) to 16 kHz mono Float32.
public final class Downmix: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    public init(input: AVAudioFormat) {
        output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioChunk.sampleRate,
                               channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: input, to: output)!
        converter.downmix = true
        converter.primeMethod = .none
    }

    public func toMono16k(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Converts a whole file-sized buffer in one go, including the tail the
    /// streaming path would carry over to the next call.
    public func toMono16kFlushing(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8192
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var samples: [Float] = []
        var fed = false
        while true {
            out.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let data = out.floatChannelData, out.frameLength > 0 {
                samples += UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))
            }
            if status != .haveData || error != nil { break }
        }
        return samples
    }
}
