import AVFoundation
import Foundation
import Testing
@testable import XlateCore

private let integration = ProcessInfo.processInfo.environment["XLATE_INTEGRATION"] == "1"
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("fixtures/out")

struct Fixture: CustomStringConvertible, Sendable {
    let name: String
    var description: String { name }

    var utterance: Utterance {
        let file = try! AVAudioFile(forReading: fixtures.appendingPathComponent("\(name).wav"))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try! file.read(into: buffer)
        return Utterance(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }

    var expected: (language: String, text: String) {
        let line = try! String(contentsOf: fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8)
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1)
        return (String(parts[0]), String(parts[1]))
    }
}

/// Word error rate after lowercasing and dropping punctuation.
func wordErrorRate(_ hypothesis: String, _ reference: String) -> Double {
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    let h = words(hypothesis), r = words(reference)
    var row = Array(0...h.count)
    for i in 1...max(r.count, 1) where !r.isEmpty {
        var next = [i] + Array(repeating: 0, count: h.count)
        for j in 1...max(h.count, 1) where !h.isEmpty {
            next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        row = next
    }
    return r.isEmpty ? 0 : Double(row[h.count]) / Double(r.count)
}

let portugueseFixtures = (1...5).map { Fixture(name: "pt_\($0)") }
let englishFixtures = (1...3).map { Fixture(name: "en_\($0)") }

func transcribers() -> [any Transcriber] { [WhisperTranscriber.shared] }

@Suite(.enabled(if: integration), .serialized)
struct TranscriberIntegrationTests {
    @Test(arguments: portugueseFixtures)
    func portugueseIsRecognized(_ fixture: Fixture) async throws {
        for transcriber in transcribers() {
            #expect(try await transcriber.prepare() == .ready)
            let result = try await transcriber.transcribe(fixture.utterance)
            #expect(result.language == .portuguese, "\(type(of: transcriber)): \(result.text)")
            let wer = wordErrorRate(result.text, fixture.expected.text)
            #expect(wer < 0.2, "\(type(of: transcriber)) WER \(wer): \(result.text)")
        }
    }

    @Test(arguments: englishFixtures)
    func englishIsRecognized(_ fixture: Fixture) async throws {
        for transcriber in transcribers() {
            let result = try await transcriber.transcribe(fixture.utterance)
            #expect(result.language == .english, "\(type(of: transcriber)): \(result.text)")
        }
    }

    @Test func loanwordSentenceIsPortuguese() async throws {
        for transcriber in transcribers() {
            let result = try await transcriber.transcribe(Fixture(name: "pt_3").utterance)
            #expect(result.language == .portuguese, "\(type(of: transcriber)): \(result.text)")
        }
    }
}

@Test func wordErrorRateCountsSubstitutions() {
    #expect(wordErrorRate("vamos fazer o deploy", "Vamos fazer o deploy.") == 0)
    #expect(wordErrorRate("vamos fazer um deploy", "vamos fazer o deploy") == 0.25)
}
