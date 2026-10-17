/// Tap chunks → speech gate → transcriber → filter → translator → captions.
///
/// Utterances are handled one at a time. If speech arrives faster than it can
/// be transcribed, only the newest waiting utterance is kept, so the pill never
/// falls more than one phrase behind.
public final class CaptionPipeline: Sendable {
    private let transcriber: any Transcriber
    private let translator: any Translator
    private let gateConfig: SpeechGate.Config

    public init(transcriber: any Transcriber, translator: any Translator, gateConfig: SpeechGate.Config = .default) {
        self.transcriber = transcriber
        self.translator = translator
        self.gateConfig = gateConfig
    }

    public func run(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<Caption> {
        captions(from: utterances(from: chunks))
    }

    func utterances(from chunks: AsyncStream<AudioChunk>) -> AsyncStream<Utterance> {
        let config = gateConfig
        return AsyncStream { continuation in
            let task = Task {
                var gate = SpeechGate(config: config)
                for await chunk in chunks {
                    for utterance in gate.push(chunk) { continuation.yield(utterance) }
                }
                if let last = gate.flush() { continuation.yield(last) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func captions(from utterances: AsyncStream<Utterance>) -> AsyncStream<Caption> {
        let (waiting, waitingInput) = AsyncStream<Utterance>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let transcriber = transcriber
        let translator = translator
        return AsyncStream { continuation in
            let forward = Task {
                for await utterance in utterances { waitingInput.yield(utterance) }
                waitingInput.finish()
            }
            let work = Task {
                for await utterance in waiting {
                    guard let transcript = try? await transcriber.transcribe(utterance),
                          CaptionFilter.accepts(transcript),
                          let english = try? await translator.translate(transcript.text)
                    else { continue }
                    continuation.yield(Caption(english: english, portuguese: transcript.text))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forward.cancel()
                work.cancel()
            }
        }
    }
}
