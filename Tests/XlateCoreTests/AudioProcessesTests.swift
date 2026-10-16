import Testing
@testable import XlateCore

@Test func matchesTeamsAndHelpers() {
    let list = [
        AudioProcess(objectID: 1, pid: 10, bundleID: "com.microsoft.teams2", isRunningOutput: false),
        AudioProcess(objectID: 2, pid: 11, bundleID: "com.microsoft.teams2.helper", isRunningOutput: true),
        AudioProcess(objectID: 3, pid: 12, bundleID: "com.apple.Music", isRunningOutput: true),
        AudioProcess(objectID: 4, pid: 13, bundleID: nil, isRunningOutput: true),
    ]
    #expect(AudioProcesses.matching("com.microsoft.teams2", in: list).map(\.pid) == [10, 11])
}
