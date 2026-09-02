import Foundation

public struct ModelResponse: Sendable, Equatable {
    public let text: String
    /// 实际产出这个回答的提供方。经过路由后，调用方需要知道到底是谁答的。
    public let providerID: ModelProviderID

    public init(text: String, providerID: ModelProviderID) {
        self.text = text
        self.providerID = providerID
    }
}

/// 流式输出的一片。
///
/// **携带的是累积快照，不是增量。** UI 应当直接赋值（`text = chunk.cumulativeText`），
/// 不要 append。
///
/// 这个取舍来自实测：Apple Foundation Models 的 `streamResponse` 吐的是累积快照，
/// 且在生成结构化内容时**会修订先前已吐出的部分**；而云端 SSE 吐的是增量 delta。
/// 两种语义必须统一，否则每个调用点都要分别处理。
/// 统一到快照是无损的（增量累加即得快照），统一到增量则需要对快照做 diff —— 一旦模型
/// 修订前文，diff 就会产出错误结果。所以这里选快照。
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
