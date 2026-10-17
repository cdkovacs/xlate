import AppKit
import Observation
import SwiftUI
import XlateCore

@MainActor @Observable
final class PillModel {
    var caption = Caption(english: "", portuguese: "")
}

/// The caption pill: English on top, the Portuguese it came from underneath.
struct PillView: View {
    let model: PillModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(Color(red: 0.23, green: 0.82, blue: 0.42))
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(model.caption.english)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            Text(model.caption.portuguese)
                .font(.system(size: 12).italic())
                .foregroundStyle(Color(white: 0.73))
                .padding(.leading, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: PillPanel.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08, opacity: 0.88)))
    }
}

/// Floating, non-activating panel: stays above full-screen Teams on every
/// Space, can be dragged, and never takes focus or keystrokes from Teams.
@MainActor
final class PillPanel: NSPanel {
    static let width: CGFloat = 400
    static let originKey = "pillOrigin"

    private let model = PillModel()
    private var fadeTimer: Timer?
    private var placed = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        alphaValue = 0
        contentView = NSHostingView(rootView: PillView(model: model))
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.saveOrigin() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ caption: Caption) {
        model.caption = caption
        resizeKeepingTop()
        if !placed {
            setFrameOrigin(restoredOrigin())
            placed = true
        }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: PillTiming.fadeAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        fadeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                if self?.alphaValue == 0 { self?.orderOut(nil) }
            }
        }
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        setFrameOrigin(restoredOrigin())
    }

    private func resizeKeepingTop() {
        guard let content = contentView else { return }
        let height = content.fittingSize.height
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: placed ? top - height : frame.minY, width: Self.width, height: height),
                 display: true)
    }

    /// Saved position (position only, never content), clamped onto a screen.
    private func restoredOrigin() -> CGPoint {
        let main = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fallback = PillPlacement.defaultOrigin(size: frame.size, in: main)
        guard let saved = UserDefaults.standard.string(forKey: Self.originKey) else { return fallback }
        return PillPlacement.clamp(origin: NSPointFromString(saved), size: frame.size,
                                   visibleFrames: NSScreen.screens.map(\.visibleFrame), preferred: main)
    }

    private func saveOrigin() {
        guard placed else { return }
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}
