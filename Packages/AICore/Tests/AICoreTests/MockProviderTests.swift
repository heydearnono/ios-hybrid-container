import Testing
import Foundation
@testable import AICore

// 这些测试刻意不碰任何真实模型：本机没有 Apple Intelligence、没有真机，
// 端侧模型一行都跑不起来。全部逻辑仍然要能被确定性验证 —— 这是「纯 AI 开发」的底线要求。

@Suite("Mock 提供方")
struct MockProviderTests {
    @Test("respond 返回脚本化的回答")
    func respondsWithScriptedReply() async throws {
        let mock = MockLanguageModelProvider(behavior: MockBehavior(replies: ["你好"]))
        let response = try await mock.respond(to: ModelRequest(prompt: "hi"))

        #expect(response.text == "你好")
        #expect(response.providerID == .mock)
    }

    @Test("流式输出的每一片都是累积快照，不是增量")
    func streamsCumulativeSnapshots() async throws {
        let mock = MockLanguageModelProvider(
            behavior: MockBehavior(replies: ["abcdef"], chunkCount: 3)
        )

        var received: [String] = []
        var finalCount = 0
        for try await chunk in mock.streamResponse(to: ModelRequest(prompt: "hi")) {
            received.append(chunk.cumulativeText)
            if chunk.isFinal { finalCount += 1 }
        }

        #expect(received == ["ab", "abcd", "abcdef"])
        #expect(finalCount == 1)
        // 每一片都必须是前一片的前缀扩展 —— 这是快照语义的定义。
        for (earlier, later) in zip(received, received.dropFirst()) {
            #expect(later.hasPrefix(earlier))
        }
    }

    @Test("error 被设置时 respond 抛出该错误")
    func throwsScriptedError() async throws {
        let mock = MockLanguageModelProvider(
            behavior: MockBehavior(error: .guardrailViolation)
        )
        await #expect(throws: ModelError.guardrailViolation) {
            _ = try await mock.respond(to: ModelRequest(prompt: "hi"))
        }
    }
}
