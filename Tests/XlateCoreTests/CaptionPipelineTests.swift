import Foundation
import Testing
@testable import XlateCore

/// Returns scripted transcripts. The utterance's first sample is the index
/// into the script, so tests control which transcript each utterance gets.
private actor FakeTranscriber: Transcriber {
    let script: [Transcript]
    let delay: Duration
    private(set) var calls: [Int] = []

    init(_ script: [Transcript], delay: Duration = .zero) {
        self.script = script
        self.delay = delay
    }

    func prepare() async throws -> EngineStatus { .ready }

    func transcribe(_ utterance: Utterance) async throws -> Transcript {
        let index = Int(utterance.samples[0])
        calls.append(index)
        try await Task.sleep(for: delay)
        return script[index]
    }
}

private actor FakeTranslator: Translator {
    var failFirst: Bool

    init(failFirst: Bool = false) {
        self.failFirst = failFirst
    }

    func prepare() async throws -> EngineStatus { .ready }

    func translate(_ portuguese: String) async throws -> String {
        if failFirst {
            failFirst = false
            throw CancellationError()
        }
        return "fake:\(portuguese)"
    }
}

private func utterances(_ count: Int, spacing: Duration = .zero) -> AsyncStream<Utterance> {
    AsyncStream { continuation in
        Task {
            for i in 0..<count {
                continuation.yield(Utterance(samples: [Float(i)] + Array(repeating: 0, count: 16_000)))
                try? await Task.sleep(for: spacing)
            }
            continuation.finish()
        }
    }
}

private func collect(_ stream: AsyncStream<Caption>) async -> [Caption] {
    var out: [Caption] = []
    for await caption in stream { out.append(caption) }
    return out
}

private let pt = Transcript(text: "vamos fazer o deploy", language: .portuguese, duration: 1.0)
private let pt2 = Transcript(text: "acho que dá pra fechar", language: .portuguese, duration: 1.0)

@Test func englishIsDropped() async {
    let pipeline = CaptionPipeline(
        transcriber: FakeTranscriber([Transcript(text: "can you see my screen", language: .english, duration: 1)]),
        translator: FakeTranslator())
    #expect(await collect(pipeline.captions(from: utterances(1))).isEmpty)
}

@Test func shortJunkIsDropped() async {
    let pipeline = CaptionPipeline(
        transcriber: FakeTranscriber([Transcript(text: "é", language: .portuguese, duration: 0.3)]),
        translator: FakeTranslator())
    #expect(await collect(pipeline.captions(from: utterances(1))).isEmpty)
}

@Test func portugueseIsTranslated() async {
    let pipeline = CaptionPipeline(transcriber: FakeTranscriber([pt]), translator: FakeTranslator())
    #expect(await collect(pipeline.captions(from: utterances(1)))
        == [Caption(english: "fake:vamos fazer o deploy", portuguese: "vamos fazer o deploy")])
}

@Test func translatorErrorDropsOnlyThatCaption() async {
    let pipeline = CaptionPipeline(transcriber: FakeTranscriber([pt, pt2]), translator: FakeTranslator(failFirst: true))
    #expect(await collect(pipeline.captions(from: utterances(2))).map(\.portuguese) == [pt2.text])
}

@Test func backlogKeepsNewest() async {
    let script = (0..<5).map { Transcript(text: "frase número \($0)", language: .portuguese, duration: 1) }
    let transcriber = FakeTranscriber(script, delay: .milliseconds(300))
    let pipeline = CaptionPipeline(transcriber: transcriber, translator: FakeTranslator())
    let captions = await collect(pipeline.captions(from: utterances(5, spacing: .milliseconds(20))))
    #expect(captions.map(\.portuguese) == ["frase número 0", "frase número 4"])
}

@Test(arguments: [
    (Transcript(text: "vamos fazer o deploy", language: .portuguese, duration: 1.2), true),
    (Transcript(text: "ok", language: .portuguese, duration: 1.2), false),
    (Transcript(text: "vamos lá", language: .portuguese, duration: 0.4), false),
    (Transcript(text: "let's go then", language: .english, duration: 1.2), false),
    (Transcript(text: "", language: .unknown, duration: 1.2), false),
])
func filterAcceptsOnlyRealPortuguese(_ transcript: Transcript, _ accepted: Bool) {
    #expect(CaptionFilter.accepts(transcript) == accepted)
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["XLATE_INTEGRATION"] == "1"), .serialized)
struct CaptionPipelineIntegrationTests {
    @Test func loanwordSentenceIsPortuguese() async throws {
        // "Vamos fazer o deploy depois da sprint review." must not be dropped as English.
        let transcriber = WhisperTranscriber.shared
        let translator = AppleTranslator()
        _ = try await transcriber.prepare()
        _ = try await translator.prepare()
        let pipeline = CaptionPipeline(transcriber: transcriber, translator: translator)
        let input = AsyncStream<Utterance> { continuation in
            continuation.yield(Fixture(name: "pt_3").utterance)
            continuation.finish()
        }
        let captions = await collect(pipeline.captions(from: input))
        #expect(captions.count == 1)
        #expect(captions.first?.english.lowercased().contains("deploy") == true, "\(captions)")
    }
}
