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

    /// 一条消息。
    ///
    /// 四个字段的组合决定了它是哪种消息，这是 OpenAI 线格式的既有形状：
    /// - system / user：`role` + `content`
    /// - assistant 只调工具：`content` 为 `null`，`tool_calls` 非空
    /// - assistant 边说边调：两者同时非空 —— spec 不禁止，**两种都要能处理**
    /// - 工具结果：`role: "tool"` + `content` + `tool_call_id`
    ///
    /// `content` 因此必须是可选的。合成的 `encode` 对 Optional 走 `encodeIfPresent`，
    /// 所以 `nil` 字段不会出现在请求体里。
    ///
    /// ⚠️ tool 消息里**没有 `name` 字段**（spec v2.3.0 里带 `name` 的是已废弃的
    /// `role: "function"`）。这里不发，但解码要容忍服务端多给。
    struct Message: Codable, Equatable {
        var role: String
        var content: String?
        var tool_calls: [ToolCall]?
        var tool_call_id: String?

        init(
            role: String, content: String? = nil,
            tool_calls: [ToolCall]? = nil, tool_call_id: String? = nil
        ) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
            self.tool_call_id = tool_call_id
        }
    }

    /// 非流式响应里的一次工具调用，也是回传 assistant 消息时要原样填回的形状。
    struct ToolCall: Codable, Equatable {
        struct Function: Codable, Equatable {
            var name: String
            /// **JSON 编码的字符串，不是对象**。spec 明确警告它可能不是合法 JSON。
            var arguments: String
        }
        var id: String
        var type: String?
        var function: Function

        init(id: String, type: String? = "function", function: Function) {
            self.id = id
            self.type = type
            self.function = function
        }
    }

    /// 工具定义。
    ///
    /// **Chat Completions 把函数嵌一层 `function`**（Responses API 是扁平的，别抄错）。
    struct ToolDefinition: Encodable {
        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: JSONValue?
            var strict: Bool?
        }
        var type = "function"
        var function: Function
    }

    /// `tool_choice` 既可能是字符串也可能是对象，所以手写编码。
    enum ToolChoiceWire: Encodable {
        case auto
        case none
        case required
        case function(String)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auto: try container.encode("auto")
            case .none: try container.encode("none")
            case .required: try container.encode("required")
            case .function(let name):
                try container.encode(
                    JSONValue.object([
                        "type": .string("function"),
                        "function": .object(["name": .string(name)]),
                    ]))
            }
        }
    }

    struct ChatRequest: Encodable {
        var model: String
        var messages: [Message]
        var stream: Bool
        var temperature: Double?
        var max_tokens: Int?
        /// 无工具时**整个字段省掉**，而不是发空数组 —— 部分兼容实现见到 `tools: []` 会报错。
        var tools: [ToolDefinition]?
        var tool_choice: ToolChoiceWire?
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
        /// 流式工具调用的一片。
        ///
        /// **整个契约就是 `required: [index]`** —— 除 `index` 外每个字段都可缺席。
        /// `id` / `type` / `function.name` 只在该 `index` 的首帧出现，
        /// `function.arguments` 逐帧追加。拼接逻辑在 `ToolCallAccumulator`。
        ///
        /// 注意这个 `index` 是该调用在 `message.tool_calls` 里的下标，
        /// **与 `choices[].index` 无关**。
        struct ToolCallChunk: Decodable {
            struct FunctionChunk: Decodable {
                var name: String?
                var arguments: String?
            }
            var index: Int
            var id: String?
            var type: String?
            var function: FunctionChunk?
        }
        struct Delta: Decodable {
            var content: String?
            var tool_calls: [ToolCallChunk]?
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
