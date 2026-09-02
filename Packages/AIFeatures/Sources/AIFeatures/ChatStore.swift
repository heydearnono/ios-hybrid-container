import Foundation
import Observation
import AICore

/// 聊天界面的状态机。
///
/// 刻意与 SwiftUI 视图分离，所以它能在没有 UI、没有模拟器、没有真实模型的情况下被测试。
@MainActor
@Observable
public final class ChatStore {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isResponding = false
    public private(set) var availability: ModelAvailability?
    public private(set) var lastError: String?
    /// 最近一次路由结果的可读说明，直接显示给用户。
    public private(set) var routingNote: String?

    public var draft: String = ""

    private let provider: any LanguageModelProvider
    private let privacy: PrivacyRequirement
    private var activeTask: Task<Void, Never>?

    public init(
        provider: any LanguageModelProvider,
        privacy: PrivacyRequirement = .any
    ) {
        self.provider = provider
        self.privacy = privacy
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding
    }

    public func refreshAvailability() async {
        availability = await provider.availability()
    }

    public func send() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }

        draft = ""
        lastError = nil
        isResponding = true
        messages.append(ChatMessage(role: .user, text: prompt))

        let placeholder = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(placeholder)

        let request = ModelRequest(prompt: prompt, privacy: privacy)

        do {
            for try await chunk in provider.streamResponse(to: request) {
                // 注意是**赋值**而不是 append：chunk 携带的是累积快照。
                // 见 AICore.ModelResponseChunk 的说明。
                update(placeholder.id) { $0.text = chunk.cumulativeText }
            }
            update(placeholder.id) { $0.isStreaming = false }
        } catch {
            let description = (error as? ModelError)?.localizedDescription
                ?? error.localizedDescription
            lastError = description
            // 失败时不留空气泡：把占位气泡撤掉，错误单独显示。
            messages.removeAll { $0.id == placeholder.id }
        }

        if let router = provider as? ModelRouter {
            routingNote = await router.lastDecision.map(Self.describe)
        }
        isResponding = false
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isResponding = false
    }

    // MARK: - 内部

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }

    private static func describe(_ decision: RoutingDecision) -> String {
        switch decision.reason {
        case .primaryAvailable:
            return "由 \(decision.providerID) 回答"
        case .fellBackToOnDevice(let primaryReason):
            return "云端不可用（\(primaryReason)），已降级到 \(decision.providerID)"
        case .privacyRequiredOnDevice:
            return "按隐私要求，仅在设备上处理（\(decision.providerID)）"
        }
    }
}
