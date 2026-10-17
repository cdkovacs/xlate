import Foundation
import Testing
@testable import XlateCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["XLATE_INTEGRATION"] == "1"))
struct TranslatorIntegrationTests {
    @Test func translatesPortugueseToEnglish() async throws {
        let translator = AppleTranslator()
        #expect(try await translator.prepare() == .ready)
        let english = try await translator.translate("Ainda precisamos confirmar a data do deploy com o cliente.")
        let lower = english.lowercased()
        #expect(lower.contains("confirm") && lower.contains("date") && lower.contains("client"), "\(english)")
    }
}
