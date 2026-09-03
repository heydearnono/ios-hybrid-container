import Foundation

/// 中立的工具参数 schema。
///
/// **为什么要自己定义一层而不直接用 JSON Schema**：端侧 `GenerationSchema` 只接受它自己那套
/// 私有方言（必须带 `title` 与无文档的 `x-order`，漏写属性会被静默丢弃），
/// 而云端要的是标准 JSON Schema。两边都不能当单一事实源，所以中间放一个自己的 DSL，
/// 向两侧各出一个 adapter。详见 `docs/05-agent-arch/tool-calling.md`。
///
/// **表达力刻意取端侧的能力做上限**（`type` / `enum` / `minimum` / `maximum` /
/// `minItems` / `maxItems` / `pattern`），这样就不会出现「云端能表达、端侧表达不了」的漏。
/// 未支持：`$ref` 递归引用、`anyOf` 多态、`const`。需要时再加，别提前抽象。
public struct ToolSchema: Sendable, Equatable {
    public indirect enum Kind: Sendable, Equatable {
        case string(pattern: String?)
        case integer(minimum: Int?, maximum: Int?)
        case number(minimum: Double?, maximum: Double?)
        case boolean
        /// 编码成 `{"type":"string","enum":[...]}`，两侧都认。
        case enumeration(cases: [String])
        case array(element: ToolSchema, minimumElements: Int?, maximumElements: Int?)
        /// `name` 只有端侧用得上（它要求每层 object 都有 `title`），云端会丢掉。
        case object(name: String, properties: [Property])
    }

    /// 对象的一个属性。
    ///
    /// `isOptional` 的语义在两侧不一样，这是**已知的不对等**：端侧靠「不进 `required`」表达，
    /// 云端 strict 模式要求所有字段都进 `required`、可选性用 `"type":["string","null"]` 表达。
    /// 转换器各自处理，调用方只管声明意图。
    public struct Property: Sendable, Equatable {
        public var name: String
        public var schema: ToolSchema
        public var isOptional: Bool

        public init(name: String, schema: ToolSchema, isOptional: Bool = false) {
            self.name = name
            self.schema = schema
            self.isOptional = isOptional
        }
    }

    public var kind: Kind
    public var description: String?

    public init(kind: Kind, description: String? = nil) {
        self.kind = kind
        self.description = description
    }
}

// MARK: - 构造器

extension ToolSchema {
    public static func string(description: String? = nil, pattern: String? = nil) -> ToolSchema {
        ToolSchema(kind: .string(pattern: pattern), description: description)
    }

    public static func integer(
        description: String? = nil, minimum: Int? = nil, maximum: Int? = nil
    ) -> ToolSchema {
        ToolSchema(kind: .integer(minimum: minimum, maximum: maximum), description: description)
    }

    public static func number(
        description: String? = nil, minimum: Double? = nil, maximum: Double? = nil
    ) -> ToolSchema {
        ToolSchema(kind: .number(minimum: minimum, maximum: maximum), description: description)
    }

    public static func boolean(description: String? = nil) -> ToolSchema {
        ToolSchema(kind: .boolean, description: description)
    }

    public static func enumeration(_ cases: [String], description: String? = nil) -> ToolSchema {
        ToolSchema(kind: .enumeration(cases: cases), description: description)
    }

    public static func array(
        of element: ToolSchema, description: String? = nil,
        minimumElements: Int? = nil, maximumElements: Int? = nil
    ) -> ToolSchema {
        ToolSchema(
            kind: .array(
                element: element, minimumElements: minimumElements,
                maximumElements: maximumElements),
            description: description)
    }

    public static func object(
        name: String, description: String? = nil, properties: [Property]
    ) -> ToolSchema {
        ToolSchema(kind: .object(name: name, properties: properties), description: description)
    }

    /// 空参数表。云端可以整个省掉 `parameters`，但显式给一个空 object 更好调试。
    public static func empty(name: String = "Empty") -> ToolSchema {
        .object(name: name, properties: [])
    }
}

// MARK: - 云端：标准 JSON Schema

extension ToolSchema {
    /// 转成 OpenAI 兼容的 JSON Schema。
    ///
    /// - Parameter strict: 对应 OpenAI 的 `strict: true` 模式。开启时每层 object 都会带
    ///   `additionalProperties: false`，且**所有**属性都进 `required` ——
    ///   可选属性改用 `"type": ["string", "null"]` 表达，这是 spec 明文要求的写法。
    ///   关闭时可选属性就只是不出现在 `required` 里。
    public func jsonSchema(strict: Bool = true) -> JSONValue {
        var node: [String: JSONValue] = [:]
        if let description { node["description"] = .string(description) }

        switch kind {
        case .string(let pattern):
            node["type"] = .string("string")
            if let pattern { node["pattern"] = .string(pattern) }
        case .integer(let minimum, let maximum):
            node["type"] = .string("integer")
            if let minimum { node["minimum"] = .int(minimum) }
            if let maximum { node["maximum"] = .int(maximum) }
        case .number(let minimum, let maximum):
            node["type"] = .string("number")
            if let minimum { node["minimum"] = .double(minimum) }
            if let maximum { node["maximum"] = .double(maximum) }
        case .boolean:
            node["type"] = .string("boolean")
        case .enumeration(let cases):
            node["type"] = .string("string")
            node["enum"] = .array(cases.map { .string($0) })
        case .array(let element, let minimumElements, let maximumElements):
            node["type"] = .string("array")
            node["items"] = element.jsonSchema(strict: strict)
            if let minimumElements { node["minItems"] = .int(minimumElements) }
            if let maximumElements { node["maxItems"] = .int(maximumElements) }
        case .object(_, let properties):
            node["type"] = .string("object")
            var encoded: [String: JSONValue] = [:]
            for property in properties {
                var child = property.schema.jsonSchema(strict: strict)
                if strict, property.isOptional { child = child.allowingNull() }
                encoded[property.name] = child
            }
            node["properties"] = .object(encoded)
            node["required"] = .array(
                properties
                    .filter { strict || !$0.isOptional }
                    .map { .string($0.name) })
            node["additionalProperties"] = .bool(false)
        }
        return .object(node)
    }
}

extension JSONValue {
    /// 把 `"type": "string"` 改写成 `"type": ["string", "null"]`。
    /// strict 模式下表达可选字段的唯一合法写法。
    fileprivate func allowingNull() -> JSONValue {
        guard case .object(var node) = self else { return self }
        switch node["type"] {
        case .string(let name) where name != "null":
            node["type"] = .array([.string(name), .string("null")])
        case .array(let names) where !names.contains(.string("null")):
            node["type"] = .array(names + [.string("null")])
        default:
            break
        }
        return .object(node)
    }
}
