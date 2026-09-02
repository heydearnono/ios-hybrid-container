import Testing
import Foundation
@testable import AICore

// 这一组测试守的是整个项目里最贵的一条经验：
// 端侧模型在资源未就绪时，`respond()` 会**挂死且不抛错**（2026-09-01 实测，300s / 90s
// 两次均未返回）。因此超时必须由抽象层强制施加，且必须能扛住「不响应取消」的上游。
// 结论出处：docs/01-on-device-llm/foundation-models-overview.md

@Suite("超时保护")
struct TimeoutTests {
    /// 测试里用很短的预算，避免拖慢反馈循环。
    private static let budget = Duration.milliseconds(200)

    @Test("上游挂死且不响应取消时，调用方仍能在预算内被解除阻塞")
    func hangingProviderStillTimesOut() async throws {
        let hanging = MockLanguageModelProvider(
            id: "hanging", isOnDevice: true, behavior: MockBehavior(hangsForever: true)
        )
        let router = ModelRouter(primary: hanging)

        let start = ContinuousClock.now
        await #expect(throws: ModelError.timedOut(Self.budget)) {
            _ = try await router.respond(
                to: ModelRequest(prompt: "hi", timeout: Self.budget)
            )
        }
        // 宽松上界：只要没有变成永久阻塞就算通过，不去卡精确耗时（CI 上会抖）。
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("流式路径：首片迟迟不来同样会超时")
    func streamWatchdogFires() async throws {
        let hanging = MockLanguageModelProvider(
            id: "hanging", isOnDevice: true, behavior: MockBehavior(hangsForever: true)
        )
        let router = ModelRouter(primary: hanging)

        var thrown: ModelError?
        do {
            for try await _ in router.streamResponse(
                to: ModelRequest(prompt: "hi", timeout: Self.budget)
            ) {
                Issue.record("挂死的上游不应该吐出任何一片")
            }
        } catch let error as ModelError {
            thrown = error
        }

        #expect(thrown == .timedOut(Self.budget))
    }

    @Test("正常完成的操作不受超时干预")
    func fastOperationPassesThrough() async throws {
        let value = try await withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("操作自身的错误原样透出，不被替换成超时")
    func propagatesUnderlyingError() async throws {
        await #expect(throws: ModelError.guardrailViolation) {
            try await withTimeout(.seconds(5)) {
                throw ModelError.guardrailViolation
            }
        }
    }

    @Test("流式在预算内完成时不会被看门狗打断")
    func streamCompletesWithinBudget() async throws {
        let provider = MockLanguageModelProvider(
            id: "fast", behavior: MockBehavior(replies: ["abcd"], chunkCount: 2)
        )
        let router = ModelRouter(primary: provider)

        var last: ModelResponseChunk?
        for try await chunk in router.streamResponse(
            to: ModelRequest(prompt: "hi", timeout: .seconds(5))
        ) {
            last = chunk
        }

        #expect(last?.cumulativeText == "abcd")
        #expect(last?.isFinal == true)
    }
}
