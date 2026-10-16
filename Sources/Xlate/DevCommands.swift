import AVFoundation
import Foundation
import XlateCore

/// Developer subcommands. They run inside the signed bundle so they share the
/// app's audio capture permission. Only these may print call content.
enum DevCommands {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "procs":
            return procs()
        case "tap":
            return tap(Array(args.dropFirst()))
        default:
            print("usage: Xlate --dev <command>")
            return 64
        }
    }

    static func procs() -> Int32 {
        do {
            for p in try AudioProcesses.all() {
                print("pid=\(p.pid)\tobj=\(p.objectID)\toutput=\(p.isRunningOutput ? 1 : 0)\t\(p.bundleID ?? "-")")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Taps the target app for N seconds and prints RMS once per second.
    /// Writes a WAV only when --wav is given explicitly.
    static func tap(_ args: [String]) -> Int32 {
        let seconds = Int(option("--seconds", in: args) ?? "20") ?? 20
        let bundle = option("--bundle", in: args) ?? TargetApp.teamsBundleID
        let wavPath = option("--wav", in: args)
        do {
            let targets = AudioProcesses.matching(bundle, in: try AudioProcesses.all())
            guard !targets.isEmpty else {
                print("no audio processes match \(bundle)")
                return 1
            }
            print("tapping \(targets.map { "\($0.bundleID ?? "-")(\($0.pid))" }.joined(separator: ", "))")
            let tap = try ProcessTap(processes: targets.map(\.objectID))
            let file = try wavPath.map { path in
                try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioChunk.sampleRate,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                ])
            }
            let done = DispatchSemaphore(value: 0)
            Task {
                var second: [Float] = []
                var elapsed = 0
                for await chunk in tap.chunks {
                    second += chunk.samples
                    if let file {
                        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(chunk.samples.count))!
                        buffer.frameLength = buffer.frameCapacity
                        chunk.samples.withUnsafeBufferPointer {
                            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
                        }
                        try? file.write(from: buffer)
                    }
                    if second.count >= Int(AudioChunk.sampleRate) {
                        elapsed += 1
                        let rms = (second.reduce(0) { $0 + $1 * $1 } / Float(second.count)).squareRoot()
                        print(String(format: "t=%02ds rms=%.4f", elapsed, rms))
                        second.removeAll(keepingCapacity: true)
                        if elapsed >= seconds { break }
                    }
                }
                done.signal()
            }
            if done.wait(timeout: .now() + .seconds(seconds + 10)) == .timedOut {
                print("no audio delivered within \(seconds + 10)s")
            }
            tap.stop()
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
