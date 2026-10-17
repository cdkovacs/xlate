import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Translation
import XlateCore

/// Developer subcommands. They run inside the signed bundle so they share the
/// app's audio capture permission. Only these may print call content.
enum DevCommands {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "procs":
            return procs()
        case "locales":
            blocking { await locales() }
        case "setup-whisper":
            blocking {
                do {
                    try await WhisperTranscriber.installModel { print(String(format: "%.0f%%", $0 * 100)) }
                    print("installed in \(WhisperTranscriber.modelsBase.path)")
                    return 0
                } catch {
                    print("error: \(error)")
                    return 1
                }
            }
        case "pill-snapshot":
            return MainActor.assumeIsolated { pillSnapshot(args.dropFirst().first ?? "pill.png") }
        case "pill-demo":
            MainActor.assumeIsolated { pillDemo() }
        case "play-target":
            // Full app against another app's audio, muted, printing captions.
            setvbuf(stdout, nil, _IOLBF, 0)
            MainActor.assumeIsolated { runApp(target: args.dropFirst().first ?? "dev.ckovacs.xlate", devMode: true) }
        case "play":
            return play(args.dropFirst().first ?? "")
        case "live":
            blocking { await live(Array(args.dropFirst())) }
        case "engines":
            blocking { await engines(Array(args.dropFirst())) }
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

    /// Runs async dev work and exits with its result. Keeps the main thread
    /// free (dispatchMain) because Speech and Translation call back on it.
    static func blocking(_ work: @escaping @Sendable () async -> Int32) -> Never {
        Task {
            let code = await work()
            fflush(stdout)
            exit(code)
        }
        dispatchMain()
    }

    static func locales() async -> Int32 {
        let availability = LanguageAvailability()
        for source in ["pt-BR", "pt"] {
            let status = await availability.status(from: Locale.Language(identifier: source),
                                                   to: Locale.Language(identifier: "en"))
            print("translate \(source)→en: \(status)")
        }
        return 0
    }

    /// Runs a WAV through the speech gate and the transcriber, printing each
    /// utterance with its language and how long recognition took.
    static func engines(_ args: [String]) async -> Int32 {
        guard let path = args.first else {
            print("usage: Xlate --dev engines <file.wav>")
            return 64
        }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Downmix(input: buffer.format).toMono16kFlushing(buffer)
            var gate = SpeechGate()
            var utterances: [Utterance] = []
            for start in stride(from: 0, to: samples.count, by: 1600) {
                utterances += gate.push(AudioChunk(samples: Array(samples[start..<min(start + 1600, samples.count)]), hostTime: 0))
            }
            if let last = gate.flush() { utterances.append(last) }
            if let dir = option("--dump", in: args) {
                for (i, utterance) in utterances.enumerated() {
                    try writeWAV(utterance.samples, to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "u%02d.wav", i)))
                }
            }
            let transcriber = WhisperTranscriber.shared
            print("prepare: \(try await transcriber.prepare())")
            let translator = AppleTranslator()
            print("translator: \(try await translator.prepare())")
            var times: [Double] = []
            for (i, utterance) in utterances.enumerated() {
                let clock = ContinuousClock.now
                let t = try await transcriber.transcribe(utterance)
                let elapsed = ContinuousClock.now - clock
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                times.append(seconds)
                print(String(format: "#%02d %5.2fs audio  %4.2fs asr  %@  %@", i, utterance.duration, seconds,
                             "\(t.language)", t.text))
                if t.language == .portuguese {
                    let start = ContinuousClock.now
                    let english = try await translator.translate(t.text)
                    let took = ContinuousClock.now - start
                    print(String(format: "      → %4.2fs mt   %@", Double(took.components.attoseconds) / 1e18 + Double(took.components.seconds), english))
                }
            }
            let sorted = times.sorted()
            if !sorted.isEmpty {
                print(String(format: "median %.2fs  p95 %.2fs  n=%d", sorted[sorted.count / 2],
                             sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.count))
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioChunk.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }

    /// Full pipeline against the live target app. Prints only metrics unless
    /// --show-text is given, so a run can be shared without call content.
    static func live(_ args: [String]) async -> Int32 {
        let seconds = Int(option("--seconds", in: args) ?? "90") ?? 90
        let showText = args.contains("--show-text")
        do {
            let targets = AudioProcesses.matching(TargetApp.teamsBundleID, in: try AudioProcesses.all())
            guard !targets.isEmpty else {
                print("Teams is not registered with Core Audio")
                return 1
            }
            let transcriber = WhisperTranscriber.shared
            let translator = AppleTranslator()
            print("whisper: \(try await transcriber.prepare())  translator: \(try await translator.prepare())")
            let tap = try ProcessTap(processes: targets.map(\.objectID))
            let deadline = ContinuousClock.now + .seconds(seconds)
            var gate = SpeechGate()
            var n = 0
            func elapsed(since start: ContinuousClock.Instant) -> Double {
                let d = ContinuousClock.now - start
                return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            }
            for await chunk in tap.chunks {
                if ContinuousClock.now > deadline { break }
                for utterance in gate.push(chunk) {
                    n += 1
                    let start = ContinuousClock.now
                    let t = try await transcriber.transcribe(utterance)
                    let asr = elapsed(since: start)
                    var line = String(format: "#%02d %5.2fs audio  asr %4.2fs  %@ %d words", n, utterance.duration, asr,
                                      "\(t.language)", t.text.split(separator: " ").count)
                    var english = ""
                    if t.language == .portuguese && !t.text.isEmpty {
                        english = try await translator.translate(t.text)
                        line += String(format: "  total %4.2fs", elapsed(since: start))
                    }
                    print(line)
                    if showText {
                        print("     pt: \(t.text)")
                        if !english.isEmpty { print("     en: \(english)") }
                    }
                    fflush(stdout)
                }
            }
            tap.stop()
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    static let sample = Caption(english: "I think we can close that by Thursday if the tests pass.",
                                portuguese: "Acho que dá pra fechar isso até quinta se os testes passarem.")

    /// Renders the pill to a PNG without putting anything on screen.
    @MainActor
    static func pillSnapshot(_ path: String) -> Int32 {
        let model = PillModel()
        model.history.limit = 2
        model.history.push(Caption(english: "Did everyone get the agenda?", portuguese: "Todo mundo recebeu a pauta?"))
        model.history.push(Caption(english: "Let's start with the release.", portuguese: "Vamos começar pelo release."))
        model.history.push(sample)
        let renderer = ImageRenderer(content: PillView(model: model).padding(20).background(Color(white: 0.35)))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    /// Shows the real panel with sample captions for 20 s.
    @MainActor
    static func pillDemo() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = PillPanel()
        panel.show(sample)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                panel.show(Caption(english: "Did everyone see the email from yesterday?",
                                   portuguese: "Todo mundo viu o e-mail de ontem?"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(0) }
        app.run()
        exit(0)
    }

    /// Plays a file from inside Xlate.app so `play-target dev.ckovacs.xlate`
    /// can tap it.
    static func play(_ path: String) -> Int32 {
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            print("can't play \(path)")
            return 1
        }
        player.play()
        Thread.sleep(forTimeInterval: player.duration + 3)
        return 0
    }
}
