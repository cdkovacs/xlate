import CoreGraphics
import Testing
@testable import XlateCore

@Test func hiddenWithoutCaption() {
    #expect(PillTiming.isVisible(lastCaptionAt: nil, now: 100) == false)
}

@Test func visibleJustBeforeFade() {
    #expect(PillTiming.isVisible(lastCaptionAt: 10, now: 17.9) == true)
}

@Test func hiddenAtFade() {
    #expect(PillTiming.isVisible(lastCaptionAt: 10, now: 18.0) == false)
}

private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
private let pill = CGSize(width: 400, height: 70)

@Test func offscreenOriginClamps() {
    let origin = PillPlacement.clamp(origin: CGPoint(x: 5000, y: 5000), size: pill, visibleFrames: [laptop], preferred: laptop)
    #expect(laptop.contains(CGRect(origin: origin, size: pill)))
}

@Test func onscreenOriginUnchanged() {
    let origin = CGPoint(x: 300, y: 200)
    #expect(PillPlacement.clamp(origin: origin, size: pill, visibleFrames: [laptop], preferred: laptop) == origin)
}

@Test func originOnSecondScreenIsKept() {
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    let origin = CGPoint(x: 2000, y: 1000)
    #expect(PillPlacement.clamp(origin: origin, size: pill, visibleFrames: [laptop, external], preferred: laptop) == origin)
}

@Test func partlyOffscreenSlidesBackOntoThatScreen() {
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    let origin = PillPlacement.clamp(origin: CGPoint(x: 3900, y: 1400), size: pill, visibleFrames: [laptop, external], preferred: laptop)
    #expect(external.contains(CGRect(origin: origin, size: pill)))
}

@Test func defaultIsCenteredNearTop() {
    let origin = PillPlacement.defaultOrigin(size: pill, in: laptop)
    #expect(origin == CGPoint(x: 556, y: 815))
}

private func caption(_ text: String) -> Caption { Caption(english: text, portuguese: text) }

@Test func historyStartsEmpty() {
    let history = CaptionHistory(limit: 2)
    #expect(history.earlier.isEmpty)
    #expect(history.current.english.isEmpty)
}

@Test func historyKeepsOnlyLimitEarlierCaptionsOldestFirst() {
    var history = CaptionHistory(limit: 2)
    for text in ["a", "b", "c", "d"] { history.push(caption(text)) }
    #expect(history.earlier.map(\.english) == ["b", "c"])
    #expect(history.current.english == "d")
}

@Test func zeroLimitShowsOnlyCurrent() {
    var history = CaptionHistory(limit: 0)
    history.push(caption("a"))
    history.push(caption("b"))
    #expect(history.earlier.isEmpty)
    #expect(history.current.english == "b")
}

@Test func loweringLimitTrimsOldest() {
    var history = CaptionHistory(limit: 3)
    for text in ["a", "b", "c", "d"] { history.push(caption(text)) }
    history.limit = 1
    #expect(history.earlier.map(\.english) == ["c"])
}

@Test func negativeLimitClampsToZero() {
    var history = CaptionHistory(limit: -4)
    history.push(caption("a"))
    history.push(caption("b"))
    #expect(history.limit == 0)
    #expect(history.earlier.isEmpty)
}

@Test func clearForgetsEverything() {
    var history = CaptionHistory(limit: 2)
    history.push(caption("a"))
    history.push(caption("b"))
    history.clear()
    #expect(history.earlier.isEmpty)
    #expect(history.current.english.isEmpty)
}

@Test func captionSizeDefaultsToMedium() {
    #expect(CaptionSize(saved: nil) == .medium)
    #expect(CaptionSize(saved: "huge") == .medium)
}

@Test func captionSizeRestoresSavedChoice() {
    #expect(CaptionSize(saved: CaptionSize.extraLarge.rawValue) == .extraLarge)
}

@Test func captionSizesGrowInMenuOrder() {
    let scales = CaptionSize.allCases.map(\.scale)
    #expect(scales == scales.sorted())
    #expect(CaptionSize.medium.scale == 1)
}
