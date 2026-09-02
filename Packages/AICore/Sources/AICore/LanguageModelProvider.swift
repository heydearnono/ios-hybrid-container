import Foundation

/// 语言模型提供方。云端、端侧、mock、以及路由器本身都实现这个协议。
///
/// 只有 `respond` 是必须实现的；`streamResponse` 有默认实现（把完整回答当作单片快照吐出），
/// 因此接一个不支持流式的提供方不需要写额外代码。
public protocol LanguageModelProvider: Sendable {
    var id: ModelProviderID { get }

    /// 是否在设备上完成推理。`PrivacyRequirement.onDeviceOnly` 的路由判定依赖这个标记。
    var isOnDevice: Bool { get }

    func availability() async -> ModelAvailability

    func respond(to request: ModelRequest) async throws -> ModelResponse

    func streamResponse(to request: ModelRequest) -> AsyncThrowingStream<ModelResponseChunk, any Error>
}

extension LanguageModelProvider {
    public func streamResponse(
        to request: ModelRequest
    ) -> AsyncThrowingStream<ModelResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await respond(to: request)
                    continuation.yield(
                        ModelResponseChunk(cumulativeText: response.text, isFinal: true)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
