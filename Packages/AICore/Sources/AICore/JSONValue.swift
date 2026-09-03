import Foundation

/// 最小 JSON 值模型。
///
/// 为什么不用 `Any` 或 `[String: Any]`：那两者都不 `Sendable`，在严格并发下过不了；
/// 而且工具参数是**模型生成的**，随时可能不是预期形状 —— 需要一个能被穷举检查的类型，
/// 而不是一路 `as?` 下去。
///
/// 只有两处需要它：把中立的工具 schema 转成 JSON Schema 发给云端，
/// 以及解析模型回吐的工具参数。
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Int 先试：JSON 不区分整数与浮点，但 `7` 解成 `7.0` 会让错误信息很难看。
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "不是合法的 JSON 值"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// 从 JSON 文本解析。**云端回吐的工具参数是字符串，且不保证是合法 JSON**
    /// （OpenAI 的 spec 自己就这么警告），所以这里返回可选而不是崩。
    public init?(jsonText: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8))
        else { return nil }
        self = value
    }

    /// 键排序输出，好让测试和日志可比对。
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let properties) = self else { return nil }
        return properties[key]
    }
}
