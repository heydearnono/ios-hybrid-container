import Foundation
import AICore

/// 装配点。App 只调这里，不直接 new 提供方 —— 这样替换实现不需要动 UI 代码。
public enum ProviderFactory {
    /// 当前可交付的装配：云端主线用 mock 顶着，端侧固定报不可用。
    ///
    /// 端侧那一档**不是占位敷衍，而是如实复刻本机实测状态**：
    /// iOS 26.2 模拟器上 `SystemLanguageModel.default.availability` 返回
    /// `.unavailable(.modelNotReady)`，因为模拟器复用宿主 Mac 的模型资源，
    /// 而宿主 macOS 15.7.3 没有 Apple Intelligence。
    /// 见 `docs/00-overview/environment.md`。
    ///
    /// 这样装配的好处是：UI 上的降级路径、隐私拒绝路径**现在就能被真实触发**，
    /// 不用等硬件到位。
    public static func makeDefaultRouter() -> ModelRouter {
        ModelRouter(
            primary: makeStubCloud(),
            onDevice: makeUnavailableOnDevice()
        )
    }

    /// 云端提供方的临时替身。真实实现需要后端代理 —— 密钥绝不能进客户端，
    /// 方案见 `docs/03-cloud-llm/README.md`。
    public static func makeStubCloud() -> any LanguageModelProvider {
        MockLanguageModelProvider(
            id: "cloud-stub",
            isOnDevice: false,
            behavior: MockBehavior(
                replies: [
                    """
                    这是云端提供方的替身回答。真实实现需要接自建后端代理，\
                    因为 API Key 打进 App 包体等于公开。
                    """,
                ],
                chunkCount: 12,
                perChunkDelay: .milliseconds(40)
            )
        )
    }

    /// 端侧提供方的实测状态复刻：本机永远不可用。
    public static func makeUnavailableOnDevice() -> any LanguageModelProvider {
        MockLanguageModelProvider(
            id: "on-device-foundation-models",
            isOnDevice: true,
            behavior: MockBehavior(availability: .unavailable(.modelNotReady))
        )
    }
}
