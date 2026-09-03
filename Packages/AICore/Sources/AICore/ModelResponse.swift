import Foundation

public struct ModelResponse: Sendable, Equatable {
    public let text: String
    /// 实际产出这个回答的提供方。经过路由后，调用方需要知道到底是谁答的。
    public let providerID: ModelProviderID
    /// 产出这个回答的过程中实际执行过的工具，按发生顺序。
    ///
    /// 存在的理由是可观测性：工具调用是**副作用**，调用方需要知道「模型替我做了什么」，
    /// 而不只是拿到最后那段文字。为空表示这次没调工具。
    public let toolInvocations: [ToolCallResult]

    public init(
        text: String,
        providerID: ModelProviderID,
        toolInvocations: [ToolCallResult] = []
    ) {
        self.text = text
        self.providerID = providerID
        self.toolInvocations = toolInvocations
    }
}

/// 流式输出的一片。
///
/// **携带的是累积快照，不是增量。** UI 应当直接赋值（`text = chunk.cumulativeText`），
/// 不要 append。
///
/// 这个取舍来自两侧语义的差异：Apple Foundation Models 的 `streamResponse` 吐的是
/// **累积快照**而不是 delta（WWDC25 session 286 明确这么说），而云端 SSE 吐的是增量 delta。
/// 两种语义必须统一，否则每个调用点都要分别处理。
///
/// 统一到快照是无损的（增量累加即得快照）；统一到增量则需要对快照做 diff，而 diff 只有在
/// 「后一片一定以前一片为前缀」时才正确。⚠️ 未验证：Apple 并没有承诺快照只会追加、不会修订，
/// 而结构化输出的 partially-generated 类型天然会让先前字段被填补或改写 —— 本机没有
/// Apple Intelligence，这一点**无法实测**，只能按不可逆的方向选。所以这里选快照。
/// 依据见 `docs/01-on-device-llm/foundation-models-overview.md`。
public struct ModelResponseChunk: Sendable, Equatable {
    public let cumulativeText: String
    public let isFinal: Bool

    public init(cumulativeText: String, isFinal: Bool) {
        self.cumulativeText = cumulativeText
        self.isFinal = isFinal
    }
}

public enum ModelAvailability: Sendable, Equatable {
    case available
    case unavailable(ModelUnavailableReason)

    public var isAvailable: Bool { self == .available }
}

public enum ModelUnavailableReason: Sendable, Equatable {
    /// 机型不支持（端侧：非 iPhone 15 Pro / 16+ 等）。
    case deviceNotEligible
    /// 用户没开启对应系统功能（端侧：Apple Intelligence 开关）。
    case featureDisabledByUser
    /// 模型资源尚未就绪或正在下载。本机 iOS 26.2 模拟器实测就是这个状态。
    case modelNotReady
    /// 缺少配置或凭证（云端：没有可用的代理地址 / 用户态凭证）。
    case notConfigured
    /// 当前地区不提供该能力。
    case regionUnsupported
}
