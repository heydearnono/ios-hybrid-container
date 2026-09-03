import Foundation
import Testing

@testable import AICore

/// 中立工具抽象的纯逻辑测试。**不碰网络** —— 秒级返回。
@Suite("工具抽象：schema / 参数 / 注册表")
struct ToolAbstractionTests {
    // MARK: - 工具名

    @Test("工具名按云端的严格集合校验：端侧那种带空格的名字必须被拒")
    func toolNameValidation() {
        // 经由变量而不是字面量构造：字面量会走 `ExpressibleByStringLiteral` 那条
        // `precondition` 路径，测不到 `init?`。
        func make(_ candidate: String) -> ToolName? { ToolName(candidate) }

        #expect(make("get_weather") != nil)
        #expect(make("Get-Weather-2") != nil)
        // 端侧官方示例里就有带空格的 `search contacts`，但云端不接受，所以统一按云端来。
        #expect(make("search contacts") == nil)
        #expect(make("") == nil)
        #expect(make("天气") == nil)
        #expect(make(String(repeating: "a", count: 64)) != nil)
        #expect(make(String(repeating: "a", count: 65)) == nil)
    }

    // MARK: - schema

    private static let weatherSchema = ToolSchema.object(
        name: "WeatherArgs",
        properties: [
            .init(name: "city", schema: .string(description: "城市")),
            .init(name: "days", schema: .integer(minimum: 0, maximum: 7), isOptional: true),
        ])

    @Test("strict 模式：可选字段进 required，可选性改用 [\"integer\",\"null\"] 表达")
    func strictSchema() {
        #expect(
            Self.weatherSchema.jsonSchema(strict: true).jsonText == """
                {"additionalProperties":false,"properties":{"city":{"description":"城市",\
                "type":"string"},"days":{"maximum":7,"minimum":0,\
                "type":["integer","null"]}},"required":["city","days"],"type":"object"}
                """)
    }

    @Test("非 strict 模式：可选字段就是不进 required")
    func looseSchema() {
        #expect(
            Self.weatherSchema.jsonSchema(strict: false).jsonText == """
                {"additionalProperties":false,"properties":{"city":{"description":"城市",\
                "type":"string"},"days":{"maximum":7,"minimum":0,\
                "type":"integer"}},"required":["city"],"type":"object"}
                """)
    }

    @Test("嵌套对象与数组逐层转换，约束原样落到 JSON Schema 关键字上")
    func nestedSchema() {
        let schema = ToolSchema.object(
            name: "Outer",
            properties: [
                .init(
                    name: "tags",
                    schema: .array(
                        of: .enumeration(["a", "b"]), minimumElements: 1, maximumElements: 3)),
                .init(
                    name: "point",
                    schema: .object(
                        name: "Point",
                        properties: [.init(name: "x", schema: .number(minimum: -1))])),
            ])
        #expect(
            schema.jsonSchema(strict: true).jsonText == """
                {"additionalProperties":false,"properties":{"point":{"additionalProperties":false,\
                "properties":{"x":{"minimum":-1,"type":"number"}},"required":["x"],\
                "type":"object"},"tags":{"items":{"enum":["a","b"],"type":"string"},\
                "maxItems":3,"minItems":1,"type":"array"}},"required":["tags","point"],\
                "type":"object"}
                """)
    }

    @Test("空参数表也是合法 object，不是 null")
    func emptySchema() {
        #expect(
            ToolSchema.empty().jsonSchema().jsonText == """
                {"additionalProperties":false,"properties":{},"required":[],"type":"object"}
                """)
    }

    // MARK: - 参数

    @Test("参数按需取值，类型不符与缺失分别报错")
    func argumentAccessors() throws {
        let arguments = ToolArguments(rawJSON: #"{"city":"北京","days":3,"hot":true,"f":1.5}"#)
        #expect(try arguments.string("city") == "北京")
        #expect(try arguments.int("days") == 3)
        #expect(try arguments.bool("hot") == true)
        #expect(try arguments.double("f") == 1.5)
        #expect(arguments.optionalString("nope") == nil)
        #expect(throws: ToolArgumentsError.missing(property: "nope")) {
            try arguments.string("nope")
        }
        #expect(throws: ToolArgumentsError.typeMismatch(property: "city", expected: "integer")) {
            try arguments.int("city")
        }
    }

    @Test("模型把整数写成 7.0 也接受 —— 拒收没有好处")
    func integerFromDouble() throws {
        #expect(try ToolArguments(rawJSON: #"{"n":7.0}"#).int("n") == 7)
        #expect(throws: ToolArgumentsError.typeMismatch(property: "n", expected: "integer")) {
            try ToolArguments(rawJSON: #"{"n":7.5}"#).int("n")
        }
    }

    /// spec 明确警告模型可能吐出非法 JSON，所以这条不是假想情况。
    @Test("非法 JSON 不崩，取值时如实报错并带上原文")
    func malformedArguments() {
        let arguments = ToolArguments(rawJSON: "{\"city\":")
        #expect(arguments.json == nil)
        #expect(throws: ToolArgumentsError.notJSON(raw: "{\"city\":")) {
            try arguments.string("city")
        }
    }

    @Test("空参数串当成空对象 —— 无参工具很常见")
    func emptyArguments() {
        #expect(ToolArguments(rawJSON: "").json == .object([:]))
        #expect(ToolArguments(rawJSON: "  ").json == .object([:]))
    }

    /// strict 模式下可选字段是用 `null` 表达的，取值时必须和「压根没给」同一语义，
    /// 否则每个工具实现都要自己判两遍。
    @Test("null 视同缺失")
    func nullIsMissing() {
        #expect(throws: ToolArgumentsError.missing(property: "city")) {
            try ToolArguments(rawJSON: #"{"city":null}"#).string("city")
        }
    }

    // MARK: - 注册表

    private static func echoTool(_ name: ToolName) -> AgentTool {
        AgentTool(
            name: name, description: "回显", parameters: .empty(),
            call: { arguments in "\(name):\(arguments.rawJSON)" })
    }

    @Test("下发顺序按名字排序，稳定可比对")
    func registryOrdering() {
        let registry = ToolRegistry([Self.echoTool("b_tool"), Self.echoTool("a_tool")])
        #expect(registry.all.map(\.name.rawValue) == ["a_tool", "b_tool"])
    }

    /// 少一条 tool 消息整个云端请求就非法，所以「找不到工具」也必须产出结果而不是抛错。
    @Test("未知工具返回错误文本结果，不抛错")
    func unknownTool() async {
        let registry = ToolRegistry([Self.echoTool("known")])
        let result = await registry.execute(
            ToolCallRequest(id: "call_1", name: "ghost", arguments: ToolArguments(rawJSON: "{}")))
        #expect(result.isError)
        #expect(result.id == "call_1")
        #expect(result.content.contains("ghost"))
        #expect(result.content.contains("known"))
    }

    @Test("工具抛错被转成文本结果 —— 统一收敛到云端语义")
    func throwingTool() async {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "数据库连不上" }
        }
        let registry = ToolRegistry([
            AgentTool(name: "boom", description: "", parameters: .empty(), call: { _ in throw Boom() })
        ])
        let result = await registry.execute(
            ToolCallRequest(id: "c", name: "boom", arguments: ToolArguments(rawJSON: "{}")))
        #expect(result.isError)
        #expect(result.content.contains("数据库连不上"))
    }

    @Test("并发执行但结果顺序与入参一致")
    func concurrentExecutionPreservesOrder() async {
        let registry = ToolRegistry([
            AgentTool(name: "slow", description: "", parameters: .empty()) { _ in
                try? await Task.sleep(for: .milliseconds(30))
                return "slow"
            },
            AgentTool(name: "fast", description: "", parameters: .empty()) { _ in "fast" },
        ])
        let results = await registry.execute([
            ToolCallRequest(id: "1", name: "slow", arguments: ToolArguments(rawJSON: "{}")),
            ToolCallRequest(id: "2", name: "fast", arguments: ToolArguments(rawJSON: "{}")),
        ])
        #expect(results.map(\.content) == ["slow", "fast"])
        #expect(results.map(\.id) == ["1", "2"])
    }
}

/// 流式工具调用分片的拼接。**纯逻辑**，不需要服务器。
@Suite("流式工具调用拼接")
struct ToolCallAccumulatorTests {
    private func chunk(
        index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil
    ) -> CloudWire.ChatStreamChunk.ToolCallChunk {
        .init(
            index: index, id: id, type: id == nil ? nil : "function",
            function: .init(name: name, arguments: arguments))
    }

    @Test("按 index 建表：并行调用的帧交错到达也不串味")
    func interleavedParallelCalls() throws {
        var accumulator = ToolCallAccumulator()
        accumulator.consume([chunk(index: 0, id: "call_a", name: "get_weather")])
        accumulator.consume([chunk(index: 1, id: "call_b", name: "get_time")])
        // 交错：这正是 `parallel_tool_calls` 打开时的真实形态。
        accumulator.consume([chunk(index: 0, arguments: "{\"city\":")])
        accumulator.consume([chunk(index: 1, arguments: "{\"zone\":")])
        accumulator.consume([chunk(index: 0, arguments: "\"北京\"}")])
        accumulator.consume([chunk(index: 1, arguments: "\"CST\"}")])

        let calls = try accumulator.finish()
        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls.map(\.name) == ["get_weather", "get_time"])
        #expect(try calls[0].arguments.string("city") == "北京")
        #expect(try calls[1].arguments.string("zone") == "CST")
    }

    @Test("首帧给的 id / name 不被后续帧的缺席覆盖")
    func firstFrameWins() throws {
        var accumulator = ToolCallAccumulator()
        accumulator.consume([chunk(index: 0, id: "call_a", name: "tool")])
        accumulator.consume([chunk(index: 0, arguments: "{}")])
        let calls = try accumulator.finish()
        #expect(calls.count == 1)
        #expect(calls[0].id == "call_a")
        #expect(calls[0].name == "tool")
    }

    @Test("按 index 升序输出，与到达顺序无关")
    func sortedByIndex() throws {
        var accumulator = ToolCallAccumulator()
        accumulator.consume([chunk(index: 2, id: "c", name: "t3", arguments: "{}")])
        accumulator.consume([chunk(index: 0, id: "a", name: "t1", arguments: "{}")])
        accumulator.consume([chunk(index: 1, id: "b", name: "t2", arguments: "{}")])
        #expect(try accumulator.finish().map(\.id) == ["a", "b", "c"])
    }

    /// 自己编个 id 会让下一轮请求被服务端拒掉，错误还会移位到别处 —— 所以在这里就失败。
    @Test("缺 id 或 name 就如实失败，不自己编")
    func missingFieldsFail() {
        var missingID = ToolCallAccumulator()
        missingID.consume([chunk(index: 0, name: "tool", arguments: "{}")])
        #expect(throws: ModelError.self) { try missingID.finish() }

        var missingName = ToolCallAccumulator()
        missingName.consume([chunk(index: 0, id: "call_a", arguments: "{}")])
        #expect(throws: ModelError.self) { try missingName.finish() }
    }

    @Test("没有工具调用时是空的")
    func emptyAccumulator() throws {
        var accumulator = ToolCallAccumulator()
        accumulator.consume([])
        #expect(accumulator.isEmpty)
        #expect(try accumulator.finish().isEmpty)
    }
}
