import Foundation

/// OpenAI 兼容的 chat completions 线格式。
///
/// 选这套 schema 不是偏好某家厂商，而是因为它事实上成了通用协议：各家官方端点、vLLM、
/// Ollama、以及绝大多数自建网关都接受同一套字段。换厂商通常只改 `baseURL` 和 `model`，
/// 不必动这里。
///
/// ⚠️ **未验证**：本项目至今没有对任何真实厂商端点发过请求，下面的字段形状来自公开文档，
/// 只在本地 stub 服务器上验证过收发闭环。真实接入时可能需要按厂商差异调整。
enum CloudWire {
    // MARK: - 请求

    struct Message: Codable, Equatable {
        var role: String
        var content: String
    }

    struct ChatRequest: Encodable {
        var model: String
        var messages: [Message]
        var stream: Bool
        var temperature: Double?
        var max_tokens: Int?
    }

    // MARK: - 非流式响应

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            var message: Message?
            var finish_reason: String?
        }
        var choices: [Choice]?
        var error: ErrorPayload?
    }

    // MARK: - 流式响应

    struct ChatStreamChunk: Decodable {
        struct Delta: Decodable {
            var content: String?
        }
        struct Choice: Decodable {
            var delta: Delta?
            var finish_reason: String?
        }
        var choices: [Choice]?
        var error: ErrorPayload?
    }

    // MARK: - 错误载荷

    /// 厂商在 HTTP 200 和非 200 下都可能返回这个结构。
    struct ErrorPayload: Decodable {
        var message: String?
        var type: String?
        var code: String?

        /// `code` 在不同厂商里可能是字符串也可能是数字，两种都要能解。
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
                code = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
                code = String(number)
            } else {
                code = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case message, type, code
        }
    }

    /// 流结束哨兵。这是厂商约定而非 SSE 规范的一部分，所以判断放在这一层而不是 `SSEParser`。
    static let doneSentinel = "[DONE]"

    /// `finish_reason` 表示内容被安全护栏拦下。
    ///
    /// 注意这种情况**HTTP 状态码是 200** —— 只看状态码会把它当成成功，
    /// 于是用户拿到一个莫名截断的空回答。必须在这里识别。
    static let contentFilterFinishReasons: Set<String> = ["content_filter", "safety"]
}
