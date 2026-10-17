/// Runs async work one job at a time, in call order. Used to keep a single
/// TranslationSession and WhisperKit instance from being driven by two
/// pipelines at once when the tap is rebuilt mid-caption.
public actor Serializer {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task {
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
}
