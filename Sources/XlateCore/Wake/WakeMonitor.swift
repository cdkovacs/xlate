import CoreAudio
import Foundation

public enum WakeState: Sendable, Equatable {
    /// The target app isn't running (or has no audio processes).
    case waitingForTarget
    /// The target app is running but hasn't been playing audio.
    case idle
    /// The target app is playing audio; tap these processes.
    case active(Set<AudioObjectID>)
}

/// Decides when to listen. Wakes after a second of continuous output from the
/// target app and sleeps after 30 s without any. On waking, the tap covers
/// every target audio process. After that a process joins only once it plays
/// something, so a short-lived silent helper never forces a rebuild, and
/// processes that exit just drop out.
public struct WakeMachine: Sendable {
    public static let wakeAfter: TimeInterval = 1
    public static let sleepAfter: TimeInterval = 30

    private let bundlePrefix: String
    private var state = WakeState.waitingForTarget
    private var outputSince: TimeInterval?
    private var lastOutput: TimeInterval?

    public init(bundlePrefix: String) {
        self.bundlePrefix = bundlePrefix
    }

    /// Rebuild the tap only when something we aren't tapping starts playing.
    /// Processes leaving the set don't need a rebuild.
    public static func needsRetap(tapped: Set<AudioObjectID>, wanted: Set<AudioObjectID>) -> Bool {
        !wanted.isSubset(of: tapped)
    }

    public mutating func observe(_ processes: [AudioProcess], at time: TimeInterval) -> WakeState {
        let targets = AudioProcesses.matching(bundlePrefix, in: processes)
        guard !targets.isEmpty else {
            outputSince = nil
            lastOutput = nil
            state = .waitingForTarget
            return state
        }
        let ids = Set(targets.map(\.objectID))
        let outputting = targets.contains(where: \.isRunningOutput)
        if outputting {
            outputSince = outputSince ?? time
            lastOutput = time
        } else {
            outputSince = nil
        }

        if case .active(let previous) = state {
            if !outputting, let last = lastOutput, time - last >= Self.sleepAfter {
                lastOutput = nil
                state = .idle
            } else {
                let playing = Set(targets.filter(\.isRunningOutput).map(\.objectID))
                state = .active(previous.intersection(ids).union(playing))
            }
        } else if let since = outputSince, time - since >= Self.wakeAfter {
            state = .active(ids)
        } else {
            state = .idle
        }
        return state
    }
}

/// Polls Core Audio once a second and reports wake state changes.
public final class WakeMonitor: Sendable {
    public let states: AsyncStream<WakeState>
    private let task: Task<Void, Never>

    public init(bundlePrefix: String, interval: Duration = .seconds(1)) {
        let (states, continuation) = AsyncStream<WakeState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.states = states
        task = Task {
            var machine = WakeMachine(bundlePrefix: bundlePrefix)
            var last: WakeState?
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let processes = (try? AudioProcesses.all()) ?? []
                let elapsed = ContinuousClock.now - start
                let now = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let state = machine.observe(processes, at: now)
                if state != last {
                    continuation.yield(state)
                    last = state
                }
                try? await Task.sleep(for: interval)
            }
            continuation.finish()
        }
    }

    deinit {
        task.cancel()
    }
}
