/// One stretch of speech, cut out of the stream by `SpeechGate`.
public struct Utterance: Sendable, Equatable {
    public let samples: [Float]
    public var duration: Double { Double(samples.count) / AudioChunk.sampleRate }

    public init(samples: [Float]) {
        self.samples = samples
    }
}

/// Energy-based voice activity gate. The noise floor is the quietest frame
/// of the last few seconds, tracked all the time (speech included), so steady
/// background hiss can't hide pauses. Speech starts when a few consecutive
/// frames rise above the floor and ends after a stretch of quiet. Long
/// monologues are cut so captions keep updating.
public struct SpeechGate: Sendable {
    public struct Config: Sendable {
        public var frameSize = 480                // 30 ms at 16 kHz
        public var startFactor: Float = 2         // ≈ +6 dB over the noise floor
        public var endFactor: Float = 1.5         // quiet means within ≈ 3.5 dB of it
        public var floorWindowFrames = 150        // 4.5 s of history for the floor
        public var startFrames = 3
        public var endFrames = 20                 // 600 ms of quiet ends an utterance
        public var keptTailFrames = 10            // keep 300 ms of that quiet
        public var phraseBreakAfter = 4.0         // once this long, a short pause is enough
        public var phraseBreakFrames = 7          // 210 ms, a typical phrase break
        public var maxDuration = 10.0
        public var minDuration = 0.4
        public var minimumFloor: Float = 0.001

        public static let `default` = Config()
    }

    private let config: Config
    private var pending: [Float] = []
    private var recentLevels: [Float] = []
    private var nextLevel = 0
    private var inSpeech = false
    private var loudRun: [[Float]] = []
    private var current: [Float] = []
    private var quietFrames = 0

    public init(config: Config = .default) {
        self.config = config
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
        let floor = trackFloor(rms)
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
            }
            return nil
        }

        current += frame
        quietFrames = rms < floor * config.endFactor ? quietFrames + 1 : 0
        let length = Double(current.count) / AudioChunk.sampleRate
        if quietFrames >= config.phraseBreakFrames && length >= config.phraseBreakAfter {
            let utterance = emit(current)
            reset()
            return utterance
        }
        if quietFrames >= config.endFrames {
            let trim = (config.endFrames - config.keptTailFrames) * config.frameSize
            let utterance = emit(Array(current.dropLast(trim)))
            reset()
            return utterance
        }
        if Double(current.count + config.frameSize) > config.maxDuration * AudioChunk.sampleRate {
            let utterance = emit(current)
            current = []
            return utterance
        }
        return nil
    }

    /// Records this frame's level and returns the current floor estimate.
    private mutating func trackFloor(_ rms: Float) -> Float {
        if recentLevels.count < config.floorWindowFrames {
            recentLevels.append(rms)
        } else {
            recentLevels[nextLevel] = rms
            nextLevel = (nextLevel + 1) % config.floorWindowFrames
        }
        return max(config.minimumFloor, recentLevels.min() ?? rms)
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
