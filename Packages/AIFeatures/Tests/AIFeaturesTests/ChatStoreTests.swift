import Testing
import Foundation
@testable import AIFeatures
import AICore

@MainActor
@Suite("聊天状态机")
struct ChatStoreTests {
    private func store(
        _ behavior: MockBehavior,
        privacy: PrivacyRequirement = .any
    ) -> ChatStore {
        ChatStore(
            provider: MockLanguageModelProvider(id: "test", behavior: behavior),
            privacy: privacy
        )
    }

    @Test("发送后同时出现用户消息与助手回答")
    func appendsBothMessages() async throws {
        let sut = store(MockBehavior(replies: ["好的"], chunkCount: 2))
        sut.draft = "你好"
        await sut.send()

        #expect(sut.messages.count == 2)
        #expect(sut.messages[0].role == .user)
        #expect(sut.messages[0].text == "你好")
        #expect(sut.messages[1].role == .assistant)
        #expect(sut.messages[1].text == "好的")
        #expect(sut.messages[1].isStreaming == false)
        #expect(sut.draft.isEmpty)
        #expect(sut.isResponding == false)
    }

    @Test("流式过程中用赋值而非追加，最终文本不会重复")
    func assignsSnapshotsInsteadOfAppending() async throws {
        // chunkCount 越多，如果实现写成 append，重复就越明显。
        let sut = store(MockBehavior(replies: ["abcdefgh"], chunkCount: 4))
        sut.draft = "go"
        await sut.send()

        #expect(sut.messages.last?.text == "abcdefgh")
    }

    @Test("空白输入不发送")
    func ignoresBlankDraft() async throws {
        let sut = store(MockBehavior())
        sut.draft = "   \n "
        #expect(sut.canSend == false)
        await sut.send()
        #expect(sut.messages.isEmpty)
    }

    @Test("失败时显示错误且不留空气泡")
    func surfacesErrorWithoutEmptyBubble() async throws {
        let sut = store(MockBehavior(error: .guardrailViolation))
        sut.draft = "你好"
        await sut.send()

        #expect(sut.messages.count == 1)
        #expect(sut.messages[0].role == .user)
        #expect(sut.lastError == ModelError.guardrailViolation.localizedDescription)
    }

    @Test("可用性查询结果被如实反映")
    func reflectsAvailability() async throws {
        let sut = store(MockBehavior(availability: .unavailable(.modelNotReady)))
        await sut.refreshAvailability()
        #expect(sut.availability == .unavailable(.modelNotReady))
    }
}

@MainActor
@Suite("默认装配")
struct ProviderFactoryTests {
    @Test("默认装配可用，且回答来自云端主线")
    func defaultRouterAnswersFromCloud() async throws {
        let router = ProviderFactory.makeDefaultRouter()
        #expect(await router.availability() == .available)

        let sut = ChatStore(provider: router)
        sut.draft = "你好"
        await sut.send()

        #expect(sut.messages.last?.text.isEmpty == false)
        #expect(await router.lastDecision?.providerID == "cloud-stub")
        #expect(sut.routingNote?.isEmpty == false)
    }

    @Test("要求仅端侧处理时，默认装配会如实拒绝而不是偷偷走云端")
    func onDeviceOnlyIsRefusedNotRerouted() async throws {
        let router = ProviderFactory.makeDefaultRouter()
        let sut = ChatStore(provider: router, privacy: .onDeviceOnly)
        sut.draft = "隐私数据"
        await sut.send()

        // 本机端侧永远不可用，所以这条必须失败 —— 这正是想让 UI 现在就能触发的路径。
        #expect(sut.lastError != nil)
        #expect(sut.messages.contains { $0.role == .assistant } == false)
    }
}
