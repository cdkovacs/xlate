/// One stretch of speech, cut out of the stream by `SpeechGate`.
public struct Utterance: Sendable, Equatable {
    public let samples: [Float]
    public var duration: Double { Double(samples.count) / AudioChunk.sampleRate }

    public init(samples: [Float]) {
        self.samples = samples
    }
}

/// Energy-based voice activity gate. Speech starts when a few consecutive
/// frames rise well above the running noise floor and ends after a stretch
/// of quiet. Long monologues are cut so captions keep updating.
public struct SpeechGate: Sendable {
    public struct Config: Sendable {
        public var frameSize = 480                // 30 ms at 16 kHz
        public var startFactor: Float = 4         // ≈ +12 dB over the noise floor
        public var startFrames = 3
        public var endFrames = 20                 // 600 ms of quiet ends an utterance
        public var keptTailFrames = 10            // keep 300 ms of that quiet
        public var maxDuration = 12.0
        public var minDuration = 0.4
        public var initialFloor: Float = 0.002
        public var minimumFloor: Float = 0.001

        public static let `default` = Config()
    }

    private let config: Config
    private var pending: [Float] = []
    private var floor: Float
    private var inSpeech = false
    private var loudRun: [[Float]] = []
    private var current: [Float] = []
    private var quietFrames = 0

    public init(config: Config = .default) {
        self.config = config
        floor = config.initialFloor
    }

    public mutating func push(_ chunk: AudioChunk) -> [Utterance] {
        pending += chunk.samples
        var out: [Utterance] = []
        var start = 0
        while pending.count - start >= config.frameSize {
            let frame = Array(pending[start..<start + config.frameSize])
            if let utterance = process(frame) { out.append(utterance) }
            start += config.frameSize
        }
        pending.removeFirst(start)
        return out
    }

    public mutating func flush() -> Utterance? {
        defer { reset() }
        return inSpeech ? emit(current) : nil
    }

    private mutating func process(_ frame: [Float]) -> Utterance? {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let loud = rms > floor * config.startFactor

        guard inSpeech else {
            if loud {
                loudRun.append(frame)
                if loudRun.count >= config.startFrames {
                    inSpeech = true
                    current = loudRun.flatMap { $0 }
                    loudRun = []
                    quietFrames = 0
                }
            } else {
                loudRun = []
                floor = max(config.minimumFloor, floor * 0.95 + rms * 0.05)
            }
            return nil
        }

        current += frame
        quietFrames = loud ? 0 : quietFrames + 1
        if quietFrames >= config.endFrames {
            let trim = (config.endFrames - config.keptTailFrames) * config.frameSize
            let utterance = emit(Array(current.dropLast(trim)))
            reset()
            return utterance
        }
        if Double(current.count) >= config.maxDuration * AudioChunk.sampleRate {
            let utterance = emit(current)
            current = []
            return utterance
        }
        return nil
    }

    private func emit(_ samples: [Float]) -> Utterance? {
        Double(samples.count) >= config.minDuration * AudioChunk.sampleRate ? Utterance(samples: samples) : nil
    }

    private mutating func reset() {
        inSpeech = false
        loudRun = []
        current = []
        quietFrames = 0
    }
}
