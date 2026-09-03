import Foundation

// MARK: - 中立类型 → 云端线格式

extension CloudWire.ToolDefinition {
    init(_ tool: AgentTool, strict: Bool) {
        self.init(
            function: Function(
                name: tool.name.rawValue,
                description: tool.description,
                parameters: tool.parameters.jsonSchema(strict: strict),
                strict: strict ? true : nil))
    }
}

extension CloudWire.ToolChoiceWire {
    init(_ choice: ToolChoice) {
        switch choice {
        case .auto: self = .auto
        case .none: self = .none
        case .required: self = .required
        case .specific(let name): self = .function(name.rawValue)
        }
    }
}

// MARK: - 云端线格式 → 中立类型

extension ToolCallRequest {
    init(_ call: CloudWire.ToolCall) {
        self.init(
            id: call.id, name: call.function.name,
            arguments: ToolArguments(rawJSON: call.function.arguments))
    }
}

extension CloudWire.Message {
    /// 把模型要求的工具调用**原样**装回一条 assistant 消息。
    ///
    /// **这一步不能省。** 回传工具结果之前必须先把带 `tool_calls` 的 assistant 消息填回历史，
    /// 再为每个 `tool_call_id` 各发一条 tool 消息 —— 顺序和一对一关系是 API 运行期强制的，
    /// 少一条整个请求就非法。⚠️ 这条规则官方文档没有明文，是从行为里得出的。
    static func assistant(
        content: String?, toolCalls: [ToolCallRequest]
    ) -> CloudWire.Message {
        CloudWire.Message(
            role: "assistant",
            content: (content?.isEmpty ?? true) ? nil : content,
            tool_calls: toolCalls.map {
                CloudWire.ToolCall(
                    id: $0.id,
                    function: .init(name: $0.name, arguments: $0.arguments.rawJSON))
            })
    }

    /// 工具结果。**错误也走同一个 `content`** —— OpenAI 对工具错误没有结构化约定，
    /// 自造 `is_error` 字段不会被理解，省掉这条消息会让请求非法。
    static func toolResult(_ result: ToolCallResult) -> CloudWire.Message {
        CloudWire.Message(role: "tool", content: result.content, tool_call_id: result.id)
    }
}

// MARK: - 流式拼接

/// 按 `index` 把流式工具调用分片拼回完整调用。
///
/// 规则来自 OpenAI spec（`ChatCompletionMessageToolCallChunk` 只有 `index` 是必填）：
/// `id` / `type` / `function.name` 只在该 index 的首帧出现，`function.arguments` 逐帧追加。
///
/// **必须按 index 建表，不能只认「当前工具调用」** —— 并行调用时 `index: 0` 和 `index: 1`
/// 的帧是交错到达的，只跟一个游标会把两个工具的参数串味。
struct ToolCallAccumulator {
    private struct Slot {
        var id: String?
        var name: String?
        var arguments = ""
    }
    private var slots: [Int: Slot] = [:]

    var isEmpty: Bool { slots.isEmpty }

    mutating func consume(_ chunks: [CloudWire.ChatStreamChunk.ToolCallChunk]) {
        for chunk in chunks {
            var slot = slots[chunk.index] ?? Slot()
            // `??=` 语义：首帧给的值不被后续帧的缺席覆盖。
            slot.id = slot.id ?? chunk.id
            slot.name = slot.name ?? chunk.function?.name
            slot.arguments += chunk.function?.arguments ?? ""
            slots[chunk.index] = slot
        }
    }

    /// 按 `index` 升序取出完整调用。
    ///
    /// 缺 `id` 或 `name` 就**如实失败**：没有 `id` 无法回传工具结果（服务端生成的 id
    /// 必须原样带回），自己编一个只会让下一轮请求被服务端拒掉，错误还会移位到别处。
    func finish() throws -> [ToolCallRequest] {
        try slots.sorted { $0.key < $1.key }.map { index, slot in
            guard let id = slot.id, let name = slot.name, !name.isEmpty else {
                throw ModelError.decodingFailure(
                    detail: "流式工具调用 index \(index) 缺少 "
                        + (slot.id == nil ? "id" : "function.name")
                        + "，无法回传结果")
            }
            return ToolCallRequest(
                id: id, name: name, arguments: ToolArguments(rawJSON: slot.arguments))
        }
    }
}
