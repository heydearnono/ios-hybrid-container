import Foundation

public struct RoutingDecision: Sendable, Equatable {
    public let providerID: ModelProviderID
    public let reason: RoutingReason

    public init(providerID: ModelProviderID, reason: RoutingReason) {
        self.providerID = providerID
        self.reason = reason
    }
}

public enum RoutingReason: Sendable, Equatable {
    /// 主线（云端）可用，正常路径。
    case primaryAvailable
    /// 主线不可用，降级到端侧增强路径。
    case fellBackToOnDevice(primaryReason: ModelUnavailableReason)
    /// 请求要求数据不出设备，强制走端侧。
    case privacyRequiredOnDevice
}

/// 路由器：**云端为主线，端侧做增强**。
///
/// 这个方向不是偏好，是被两件事逼出来的：
/// 1. 端侧受「机型 + Apple Intelligence 开关 + 地区」三重限制，无法作为唯一实现；
/// 2. 云端是当前环境下唯一能被机器端到端验证的路径。
/// 依据见 `docs/00-overview/ios-ai-landscape.md`。
///
/// 路由器自身也实现 `LanguageModelProvider`，所以调用方只面对一个接口，
/// 也可以把路由器再套进另一个路由器。
public actor ModelRouter: LanguageModelProvider {
    public nonisolated let id: ModelProviderID = .router

    /// 路由器不是终端提供方。`onDeviceOnly` 的判定看实际被选中的提供方，不看这里。
    public nonisolated var isOnDevice: Bool { false }

    private let primary: any LanguageModelProvider
    private let onDevice: (any LanguageModelProvider)?

    /// 最近一次路由结果，供 UI 显示「这条回答是谁答的」和测试断言。
    public private(set) var lastDecision: RoutingDecision?

    public init(
        primary: any LanguageModelProvider,
        onDevice: (any LanguageModelProvider)? = nil
    ) {
        self.primary = primary
        self.onDevice = onDevice
    }

    /// 只要有任一条路可走就算可用。
    public func availability() async -> ModelAvailability {
        let primaryAvailability = await primary.availability()
        if primaryAvailability.isAvailable { return .available }
        if let onDevice, await onDevice.availability().isAvailable { return .available }
        return primaryAvailability
    }

    /// 只做路由判定不发请求，用于 UI 预先提示走的是哪条路。
    public func route(_ request: ModelRequest) async throws -> RoutingDecision {
        try await resolve(request).decision
    }

    public func respond(to request: ModelRequest) async throws -> ModelResponse {
        let (provider, decision) = try await resolve(request)
        lastDecision = decision

        // 超时在这里强制施加，而不是信任提供方。端侧挂死过。
        return try await withTimeout(request.timeout) {
            try await provider.respond(to: request)
        }
    }

    public nonisolated func streamResponse(
        to request: ModelRequest
    ) -> AsyncThrowingStream<ModelResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let sawFirstChunk = AtomicFlag()

            let drain = Task {
                do {
                    let (provider, decision) = try await self.resolve(request)
                    await self.record(decision)
                    for try await chunk in provider.streamResponse(to: request) {
                        sawFirstChunk.set()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // 看门狗只守「首片」：挂死发生在任何输出之前，首片到了就说明链路是活的。
            // 若上游不响应取消，drain 会泄漏，但消费者一定能被解除阻塞。
            let watchdog = Task {
                try? await Task.sleep(for: request.timeout)
                guard !sawFirstChunk.isSet else { return }
                drain.cancel()
                continuation.finish(throwing: ModelError.timedOut(request.timeout))
            }

            continuation.onTermination = { _ in
                drain.cancel()
                watchdog.cancel()
            }
        }
    }

    // MARK: - 内部

    private func record(_ decision: RoutingDecision) {
        lastDecision = decision
    }

    private func resolve(
        _ request: ModelRequest
    ) async throws -> (provider: any LanguageModelProvider, decision: RoutingDecision) {
        if request.privacy == .onDeviceOnly {
            // 这里绝不允许降级到云端：静默降级会把隐私承诺变成谎言。
            guard let onDevice, onDevice.isOnDevice else {
                throw ModelError.unavailable(.notConfigured)
            }
            switch await onDevice.availability() {
            case .available:
                return (onDevice, RoutingDecision(
                    providerID: onDevice.id, reason: .privacyRequiredOnDevice
                ))
            case .unavailable(let reason):
                throw ModelError.unavailable(reason)
            }
        }

        let primaryAvailability = await primary.availability()
        if primaryAvailability.isAvailable {
            return (primary, RoutingDecision(
                providerID: primary.id, reason: .primaryAvailable
            ))
        }

        guard case .unavailable(let primaryReason) = primaryAvailability else {
            throw ModelError.unavailable(.notConfigured)
        }

        if let onDevice, await onDevice.availability().isAvailable {
            return (onDevice, RoutingDecision(
                providerID: onDevice.id,
                reason: .fellBackToOnDevice(primaryReason: primaryReason)
            ))
        }

        throw ModelError.unavailable(primaryReason)
    }
}
