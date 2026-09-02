import Foundation
import AICore

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public var text: String
    /// 这条回答实际由哪个提供方产出。云端/端侧混用时，用户有权知道数据去过哪里。
    public var providerID: ModelProviderID?
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        providerID: ModelProviderID? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.providerID = providerID
        self.isStreaming = isStreaming
    }
}
