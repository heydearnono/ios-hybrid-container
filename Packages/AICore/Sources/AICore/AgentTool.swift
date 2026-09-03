import Foundation

// MARK: - 工具名

/// 合法的工具名。
///
/// **按云端的严格约束来**：`[a-zA-Z0-9_-]`，1–64 字符（OpenAI spec v2.3.0）。
/// 端侧对工具名没有任何约束（官方示例里甚至有带空格的 `search contacts`），
/// 所以取云端这一侧一定两边都兼容。反过来就会在切换提供方时炸。
public struct ToolName: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func isValid(_ candidate: String) -> Bool {
        guard (1...64).contains(candidate.count) else { return false }
        return candidate.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    public var description: String { rawValue }
}

extension ToolName: ExpressibleByStringLiteral {
    /// 字面量走 `precondition`：工具名是写死在代码里的，非法就是编程错误，
    /// 应当在第一次跑到这行时立刻炸掉，而不是变成运行期的可选值传播。
    /// 名字来自外部输入（配置文件、服务端下发）时请用 `init?`。
    public init(stringLiteral value: String) {
        precondition(
            Self.isValid(value),
            "非法工具名 \"\(value)\"：只允许 [a-zA-Z0-9_-]，1–64 字符")
        self.rawValue = value
    }
}

// MARK: - 工具参数

/// 模型生成的工具参数。
///
/// **刻意不做成强类型。** 云端回吐的 `arguments` 是字符串，OpenAI 的 spec 自己就警告模型
/// 「does not always generate valid JSON, and may hallucinate parameters not defined by your
/// function schema」。所以这里保留原文，取值时才校验，失败信息带上原文好排查。
public struct ToolArguments: Sendable, Equatable {
    /// 模型给出的原始文本。**不保证是合法 JSON。**
    public let rawJSON: String
    private let value: JSONValue?

    public init(rawJSON: String) {
        self.rawJSON = rawJSON
        // 空字符串在实践中很常见（无参工具），当成空对象处理比报错有用。
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = trimmed.isEmpty ? .object([:]) : JSONValue(jsonText: trimmed)
    }

    public init(_ value: JSONValue) {
        self.value = value
        self.rawJSON = value.jsonText
    }

    /// 解析后的值。`nil` 表示模型吐的不是合法 JSON。
    public var json: JSONValue? { value }

    public func string(_ name: String) throws -> String {
        guard case .string(let text)? = try lookup(name) else {
            throw ToolArgumentsError.typeMismatch(property: name, expected: "string")
        }
        return text
    }

    public func int(_ name: String) throws -> Int {
        switch try lookup(name) {
        case .int(let number): return number
        // 模型经常把整数写成 `7.0`，拒收没有好处。
        case .double(let number) where number == number.rounded(): return Int(number)
        default: throw ToolArgumentsError.typeMismatch(property: name, expected: "integer")
        }
    }

    public func double(_ name: String) throws -> Double {
        switch try lookup(name) {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: throw ToolArgumentsError.typeMismatch(property: name, expected: "number")
        }
    }

    public func bool(_ name: String) throws -> Bool {
        guard case .bool(let flag)? = try lookup(name) else {
            throw ToolArgumentsError.typeMismatch(property: name, expected: "boolean")
        }
        return flag
    }

    public func optionalString(_ name: String) -> String? {
        guard case .string(let text)? = value?[name] else { return nil }
        return text
    }

    /// 缺失即抛；`null` 视同缺失 —— strict 模式下可选字段就是用 `null` 表达的。
    private func lookup(_ name: String) throws -> JSONValue? {
        guard let value else { throw ToolArgumentsError.notJSON(raw: rawJSON) }
        guard case .object(let properties) = value else {
            throw ToolArgumentsError.notJSON(raw: rawJSON)
        }
        guard let found = properties[name], found != .null else {
            throw ToolArgumentsError.missing(property: name)
        }
        return found
    }
}

public enum ToolArgumentsError: Error, Equatable, LocalizedError {
    case notJSON(raw: String)
    case missing(property: String)
    case typeMismatch(property: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .notJSON(let raw):
            return "工具参数不是合法 JSON 对象：\(raw)"
        case .missing(let property):
            return "缺少参数 \"\(property)\""
        case .typeMismatch(let property, let expected):
            return "参数 \"\(property)\" 类型不符，应为 \(expected)"
        }
    }
}

// MARK: - 工具定义

/// 中立的工具定义：一份描述同时驱动端侧与云端。
///
/// 三条设计取舍（依据见 `docs/05-agent-arch/tool-calling.md`）：
///
/// - **结果类型固定 `String`。** 两侧的公共分母：端侧 `Tool.Output` 的约束是
///   `PromptRepresentable`（`String` 满足），云端 tool message 的 `content` 本来就是字符串。
///   工具实现不必为端侧额外做 `@Generable` 建模。
/// - **`call` 应当自己咽掉业务错误、把说明当正常结果返回。** 端侧抛错会被包成
///   `ToolCallError` 抛给调用方并回滚 transcript，云端则是把错误文本喂回模型让它自愈 ——
///   两侧行为完全不同。统一收敛到云端语义，所以这里鼓励返回而不是抛。
///   真抛了也不会崩：`ToolRegistry` 会转成错误文本。
/// - **没有「单步执行」以外的东西。** 工具调用循环归属两侧不同（端侧在框架里、云端在你手里），
///   抽象层不碰。
public struct AgentTool: Sendable {
    public let name: ToolName
    /// 给模型看的说明。**这是模型决定要不要调它的唯一依据**，写清楚触发条件与参数含义。
    public let description: String
    public let parameters: ToolSchema
    public let call: @Sendable (ToolArguments) async throws -> String

    public init(
        name: ToolName,
        description: String,
        parameters: ToolSchema,
        call: @escaping @Sendable (ToolArguments) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.call = call
    }
}

/// 模型要求的一次工具调用。
public struct ToolCallRequest: Sendable, Equatable, Identifiable {
    /// 云端的 `tool_call_id`，**必须原样回传**；端侧由框架生成，只能读。
    public let id: String
    public let name: String
    public let arguments: ToolArguments

    public init(id: String, name: String, arguments: ToolArguments) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// 一次工具调用的结果。
public struct ToolCallResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let content: String
    /// **只用于日志与 UI**。回传给模型时错误和正常结果走同一个 `content` 字段 ——
    /// OpenAI 对工具错误没有任何结构化约定，自造 `is_error` 字段只会被忽略。
    public let isError: Bool

    public init(id: String, name: String, content: String, isError: Bool = false) {
        self.id = id
        self.name = name
        self.content = content
        self.isError = isError
    }
}

/// 是否/如何强制模型调工具。
public enum ToolChoice: Sendable, Equatable {
    /// 模型自己决定。两侧都支持。
    case auto
    /// 本轮禁止调工具。端侧靠「新建一个不带 tools 的 session」模拟。
    case none
    /// 必须调至少一个工具。**iOS 26.2 端侧无等价能力**（iOS 27 才有 `toolCallingMode`），
    /// 端侧实现应当如实失败而不是静默降级成 `.auto`。
    case required
    /// 必须调指定的工具。同上，**iOS 26.2 端侧无等价能力**。
    case specific(ToolName)
}

// MARK: - 注册表

/// 工具集。负责按名字派发、并发执行、以及把错误转成模型能看懂的文本。
public struct ToolRegistry: Sendable {
    private let tools: [String: AgentTool]

    public init(_ tools: [AgentTool] = []) {
        // 同名后者覆盖前者；重复注册是配置错误，但不值得为它抛错。
        self.tools = Dictionary(tools.map { ($0.name.rawValue, $0) }, uniquingKeysWith: { $1 })
    }

    public static let empty = ToolRegistry()

    public var isEmpty: Bool { tools.isEmpty }
    /// 按名字排序，保证下发给模型的顺序稳定 —— 不稳定的顺序会让请求体无法比对、
    /// 也会让端侧的 prompt 缓存失效。
    public var all: [AgentTool] { tools.values.sorted { $0.name.rawValue < $1.name.rawValue } }

    public subscript(name: String) -> AgentTool? { tools[name] }

    /// 并发执行一批工具调用，**顺序与入参一致**。
    ///
    /// 三条行为约定：
    /// - **未知工具不抛错**，返回一条错误文本结果。云端要求每个 `tool_call_id` 都必须有
    ///   对应的 tool 消息，少一条整个请求就非法 —— 所以宁可回一句「没有这个工具」。
    /// - **`call` 抛的错也不向上传播**，同样转成文本。理由同上。
    /// - **并发执行**：端侧 doc 明确说 `call` 可能被并发调用，云端 `parallel_tool_calls`
    ///   默认开。工具实现必须自己是 `Sendable` 且能并发跑。
    public func execute(_ calls: [ToolCallRequest]) async -> [ToolCallResult] {
        guard !calls.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, ToolCallResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { (index, await self.execute(call)) }
            }
            var results = [ToolCallResult?](repeating: nil, count: calls.count)
            for await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
    }

    public func execute(_ call: ToolCallRequest) async -> ToolCallResult {
        guard let tool = tools[call.name] else {
            return ToolCallResult(
                id: call.id, name: call.name,
                content: "没有名为 \"\(call.name)\" 的工具。可用工具："
                    + all.map(\.name.rawValue).joined(separator: ", "),
                isError: true)
        }
        do {
            return ToolCallResult(
                id: call.id, name: call.name, content: try await tool.call(call.arguments))
        } catch {
            // 把错误文本喂回模型让它自愈，这是云端语义；端侧适配器也按这个来。
            return ToolCallResult(
                id: call.id, name: call.name,
                content: "工具执行失败：\(error.localizedDescription)", isError: true)
        }
    }
}
