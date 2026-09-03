import Foundation

/// 模型提供方标识。用字符串包装而不是 enum，是为了让新增提供方不必改动 AICore。
public struct ModelProviderID: Sendable, Hashable, ExpressibleByStringLiteral,
                               CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static let mock: ModelProviderID = "mock"
    public static let router: ModelProviderID = "router"
    public static let cloud: ModelProviderID = "cloud"
}

/// 请求对数据去向的要求。
public enum PrivacyRequirement: Sendable, Equatable {
    /// 默认：由路由策略决定，通常走云端。
    case any
    /// 数据不得离开设备。端侧不可用时**直接失败**，绝不静默降级到云端。
    ///
    /// 这条不变量由 `ModelRouter` 保证，并有对应测试覆盖。静默降级会把隐私承诺变成谎言，
    /// 属于必须在类型层面拦住的错误。
    case onDeviceOnly
}

public struct ModelRequest: Sendable, Equatable {
    public var prompt: String
    public var systemInstructions: String?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var privacy: PrivacyRequirement

    /// 单次请求的硬超时。
    ///
    /// **不是可选项。** 端侧模型在资源未就绪时会挂死且不抛错（2026-09-01 实测，
    /// 300s / 90s 两次均未返回，见 `docs/01-on-device-llm/foundation-models-overview.md`），
    /// 因此超时保护必须由抽象层强制施加，不能指望提供方自己守规矩。
    public var timeout: Duration

    public init(
        prompt: String,
        systemInstructions: String? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        privacy: PrivacyRequirement = .any,
        timeout: Duration = .seconds(30)
    ) {
        self.prompt = prompt
        self.systemInstructions = systemInstructions
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.privacy = privacy
        self.timeout = timeout
    }
}
