import Foundation

/// Mock 提供方的脚本化行为。
public struct MockBehavior: Sendable {
    public var availability: ModelAvailability
    /// 依次返回的回答。用尽后重复最后一条。
    public var replies: [String]
    /// 非 nil 时，`respond` 直接抛出这个错误。
    public var error: ModelError?
    /// 流式模式下把回答切成几片吐出。
    public var chunkCount: Int
    public var perChunkDelay: Duration
    /// 复现端侧模型不可用时 `respond()` **挂死且不抛错**的行为，用于验证超时保护确实生效。
    public var hangsForever: Bool

    public init(
        availability: ModelAvailability = .available,
        replies: [String] = ["这是 mock 回答。"],
        error: ModelError? = nil,
        chunkCount: Int = 3,
        perChunkDelay: Duration = .zero,
        hangsForever: Bool = false
    ) {
        self.availability = availability
        self.replies = replies
        self.error = error
        self.chunkCount = chunkCount
        self.perChunkDelay = perChunkDelay
        self.hangsForever = hangsForever
    }
}

/// 可脚本化的假提供方。
///
/// 它是「纯 AI 开发」能成立的前提：本机既没有 Apple Intelligence 也没有真机，
/// 端侧模型完全跑不起来；有了它，全链路逻辑仍然能被 `swift test` 确定性地验证。
public actor MockLanguageModelProvider: LanguageModelProvider {
    public nonisolated let id: ModelProviderID
    public nonisolated let isOnDevice: Bool

    private var behavior: MockBehavior
    private var replyIndex = 0
    /// 收到过的请求，供测试断言路由是否把请求交给了正确的提供方。
    public private(set) var recordedRequests: [ModelRequest] = []

    public init(
        id: ModelProviderID = .mock,
        isOnDevice: Bool = false,
        behavior: MockBehavior = MockBehavior()
    ) {
        self.id = id
        self.isOnDevice = isOnDevice
        self.behavior = behavior
    }

    public func availability() async -> ModelAvailability {
        behavior.availability
    }

    public func update(behavior: MockBehavior) {
        self.behavior = behavior
    }

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        recordedRequests.append(request)

        if behavior.hangsForever {
            // 故意不响应取消：真实的端侧挂死就是这样，超时必须由外层保证。
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
        if let error = behavior.error { throw error }

        return ModelResponse(text: nextReply(), providerID: id)
    }

    public nonisolated func streamResponse(
        to request: ModelRequest
    ) -> AsyncThrowingStream<ModelResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let chunks = try await self.plannedChunks(for: request)
                    for chunk in chunks {
                        if Task.isCancelled { break }
                        try await self.pause()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    private func pause() async throws {
        guard behavior.perChunkDelay > .zero else { return }
        try await Task.sleep(for: behavior.perChunkDelay)
    }

    private func nextReply() -> String {
        guard !behavior.replies.isEmpty else { return "" }
        let reply = behavior.replies[min(replyIndex, behavior.replies.count - 1)]
        replyIndex += 1
        return reply
    }

    /// 把回答切成累积快照序列。注意每片都是**全量前缀**，不是增量。
    private func plannedChunks(for request: ModelRequest) async throws -> [ModelResponseChunk] {
        recordedRequests.append(request)

        if behavior.hangsForever {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
        if let error = behavior.error { throw error }

        let text = nextReply()
        let pieces = max(1, behavior.chunkCount)
        let characters = Array(text)
        guard !characters.isEmpty else {
            return [ModelResponseChunk(cumulativeText: "", isFinal: true)]
        }

        let step = max(1, Int((Double(characters.count) / Double(pieces)).rounded(.up)))
        var chunks: [ModelResponseChunk] = []
        var end = 0
        while end < characters.count {
            end = min(end + step, characters.count)
            chunks.append(
                ModelResponseChunk(
                    cumulativeText: String(characters[0..<end]),
                    isFinal: end == characters.count
                )
            )
        }
        return chunks
    }
}
