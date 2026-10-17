import Synchronization
import Testing
@testable import XlateCore

@Test func serializerNeverOverlapsWork() async throws {
    let serializer = Serializer()
    let running = Mutex(0)
    let peak = Mutex(0)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<5 {
            group.addTask {
                try await serializer.run {
                    let now = running.withLock { $0 += 1; return $0 }
                    peak.withLock { $0 = max($0, now) }
                    try await Task.sleep(for: .milliseconds(30))
                    running.withLock { $0 -= 1 }
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(peak.withLock { $0 } == 1)
}

@Test func serializerPassesResultsAndErrors() async throws {
    let serializer = Serializer()
    #expect(try await serializer.run { 42 } == 42)
    await #expect(throws: CancellationError.self) { try await serializer.run { throw CancellationError() } }
    #expect(try await serializer.run { "still works" } == "still works")
}
