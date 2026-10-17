import CoreAudio
import Foundation
import Testing
@testable import XlateCore

private func teams(_ id: UInt32, output: Bool) -> AudioProcess {
    AudioProcess(objectID: id, pid: pid_t(id + 100), bundleID: "com.microsoft.teams2.helper", isRunningOutput: output)
}

private let music = AudioProcess(objectID: 9, pid: 9, bundleID: "com.apple.Music", isRunningOutput: true)

@Test func noTeamsIsWaiting() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    #expect(machine.observe([music], at: 0) == .waitingForTarget)
}

@Test func silentTeamsIsIdle() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    #expect(machine.observe([teams(1, output: false), music], at: 0) == .idle)
}

@Test func wakesAfterOneSecondOfOutput() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    let procs = [teams(1, output: true), teams(2, output: false)]
    #expect(machine.observe(procs, at: 0) == .idle)
    #expect(machine.observe(procs, at: 0.5) == .idle)
    #expect(machine.observe(procs, at: 1.0) == .active([1, 2]))
}

@Test func briefOutputDoesNotWake() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    #expect(machine.observe([teams(1, output: true)], at: 0) == .idle)
    #expect(machine.observe([teams(1, output: false)], at: 0.5) == .idle)
    #expect(machine.observe([teams(1, output: true)], at: 1.0) == .idle)
}

@Test func sleepsAfterThirtySecondsOfSilence() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    _ = machine.observe([teams(1, output: true)], at: 0)
    _ = machine.observe([teams(1, output: true)], at: 1)
    #expect(machine.observe([teams(1, output: true)], at: 10) == .active([1]))
    #expect(machine.observe([teams(1, output: false)], at: 39) == .active([1]))
    #expect(machine.observe([teams(1, output: false)], at: 40) == .idle)
}

@Test func pidChangeReattaches() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    _ = machine.observe([teams(1, output: false), teams(2, output: true)], at: 0)
    #expect(machine.observe([teams(1, output: false), teams(2, output: true)], at: 1) == .active([1, 2]))
    #expect(machine.observe([teams(1, output: false), teams(7, output: true)], at: 2) == .active([1, 7]))
}

@Test func teamsQuittingWhileActiveIsWaiting() {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    _ = machine.observe([teams(1, output: true)], at: 0)
    _ = machine.observe([teams(1, output: true)], at: 1)
    #expect(machine.observe([music], at: 2) == .waitingForTarget)
}

private func awake(_ procs: [AudioProcess]) -> WakeMachine {
    var machine = WakeMachine(bundlePrefix: "com.microsoft.teams2")
    _ = machine.observe(procs, at: 0)
    _ = machine.observe(procs, at: 1)
    return machine
}

@Test func silentNewcomerDoesNotChangeSet() {
    var machine = awake([teams(1, output: true), teams(2, output: false)])
    #expect(machine.observe([teams(1, output: true), teams(2, output: false), teams(3, output: false)], at: 2) == .active([1, 2]))
}

@Test func outputtingNewcomerJoins() {
    var machine = awake([teams(1, output: true), teams(2, output: false)])
    #expect(machine.observe([teams(1, output: true), teams(2, output: false), teams(3, output: true)], at: 2) == .active([1, 2, 3]))
}

@Test func departedProcessLeavesSet() {
    var machine = awake([teams(1, output: true), teams(2, output: false)])
    #expect(machine.observe([teams(1, output: true)], at: 2) == .active([1]))
}

@Test(arguments: [
    (Set<AudioObjectID>([1, 2]), Set<AudioObjectID>([1]), false),
    (Set<AudioObjectID>([1, 2]), Set<AudioObjectID>([1, 2]), false),
    (Set<AudioObjectID>([1, 2]), Set<AudioObjectID>([1, 7]), true),
    (Set<AudioObjectID>(), Set<AudioObjectID>([1]), true),
])
func retapOnlyForUntappedProcesses(_ tapped: Set<AudioObjectID>, _ wanted: Set<AudioObjectID>, _ expected: Bool) {
    #expect(WakeMachine.needsRetap(tapped: tapped, wanted: wanted) == expected)
}
