import Foundation
import Testing

@testable import AICore

/// 云端工具调用的端到端测试。打的是本地真服务器 + 真 `URLSession`。
///
/// **这一层现在就能完整验证**，不依赖任何厂商凭证，也不依赖端侧模型 ——
/// 端侧那半只能等硬件，见 `docs/05-agent-arch/tool-calling.md`。
@Suite("云端工具调用")
struct CloudToolCallingTests {
    // MARK: - 夹具

    private static let noRetry = ReconnectPolicy.disabled

    private func makeProvider(
        _ server: StubHTTPServer,
        tools: ToolRegistry,
        maximumToolIterations: Int = 5,
        strict: Bool = true
    ) -> CloudLanguageModelProvider {
        CloudLanguageModelProvider(
            configuration: CloudProviderConfiguration(
                baseURL: server.baseURL, model: "test-model",
                reconnect: Self.noRetry,
                maximumToolIterations: maximumToolIterations,
                usesStrictToolSchema: strict),
            credential: { "test-token" },
            session: URLSession(configuration: .ephemeral),
            tools: tools)
    }

    /// 记录被调用的参数，好断言「模型给的参数确实传到了工具手上」。
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _seen: [String] = []
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return _seen }
        func record(_ text: String) { lock.lock(); _seen.append(text); lock.unlock() }
    }

    private func weatherTool(_ spy: Spy) -> AgentTool {
        AgentTool(
            name: "get_weather",
            description: "查询指定城市的天气",
            parameters: .object(
                name: "WeatherArgs",
                properties: [.init(name: "city", schema: .string(description: "城市名"))])
        ) { arguments in
            let city = try arguments.string("city")
            spy.record(city)
            return "\(city) 25 度"
        }
    }

    private func timeTool(_ spy: Spy) -> AgentTool {
        AgentTool(
            name: "get_time", description: "查询时间", parameters: .empty()
        ) { arguments in
            spy.record("time:\(arguments.rawJSON)")
            return "12:00"
        }
    }

    private func body(_ request: StubHTTPServer.RecordedRequest) throws -> JSONValue {
        try #require(JSONValue(jsonText: request.bodyText))
    }

    private func messages(_ body: JSONValue) -> [JSONValue] {
        guard case .array(let items)? = body["messages"] else { return [] }
        return items
    }

    // MARK: - 非流式

    @Test("非流式闭环：模型要求调工具 → 执行 → 回传 → 拿到最终回答")
    func nonStreamingRoundTrip() async throws {
        let spy = Spy()
        let server = try StubHTTPServer(replies: [
            .json(body: StubHTTPServer.openAIToolCallResponse([
                .init(id: "call_1", name: "get_weather", argumentPieces: [#"{"city":"北京"}"#])
            ])),
            .json(body: StubHTTPServer.openAIResponse(content: "北京今天 25 度。")),
        ])
        defer { server.stop() }

        let provider = makeProvider(server, tools: ToolRegistry([weatherTool(spy)]))
        let response = try await provider.respond(to: ModelRequest(prompt: "北京天气如何"))

        #expect(response.text == "北京今天 25 度。")
        #expect(spy.seen == ["北京"])
        #expect(response.toolInvocations.map(\.content) == ["北京 25 度"])
        #expect(response.toolInvocations.map(\.isError) == [false])
        #expect(server.requests.count == 2)

        // 第一轮：工具定义 + tool_choice 都在。
        let first = try body(server.requests[0])
        guard case .array(let tools)? = first["tools"] else {
            Issue.record("第一轮请求没带 tools"); return
        }
        #expect(tools.count == 1)
        #expect(tools[0]["type"] == .string("function"))
        #expect(tools[0]["function"]?["name"] == .string("get_weather"))
        #expect(tools[0]["function"]?["strict"] == .bool(true))
        #expect(tools[0]["function"]?["parameters"]?["required"] == .array([.string("city")]))
        #expect(first["tool_choice"] == .string("auto"))

        // 第二轮：先原样填回 assistant 的 tool_calls，再为每个 id 各发一条 tool 消息。
        // 这个顺序与一对一关系是 API 运行期强制的，少一条整个请求就非法。
        // 这个用例没给 systemInstructions，所以是 user + assistant + tool 三条。
        let second = messages(try body(server.requests[1]))
        #expect(second.compactMap { $0["role"] }
            == [.string("user"), .string("assistant"), .string("tool")])
    }

    @Test("回传形状：assistant 消息原样填回，每个 tool_call_id 各一条 tool 消息")
    func replayShape() async throws {
        let spy = Spy()
        let server = try StubHTTPServer(replies: [
            .json(body: StubHTTPServer.openAIToolCallResponse([
                .init(id: "call_1", name: "get_weather", argumentPieces: [#"{"city":"上海"}"#])
            ])),
            .json(body: StubHTTPServer.openAIResponse(content: "好的")),
        ])
        defer { server.stop() }

        let provider = makeProvider(server, tools: ToolRegistry([weatherTool(spy)]))
        _ = try await provider.respond(
            to: ModelRequest(prompt: "上海天气", systemInstructions: "你是助手"))

        let sent = messages(try body(server.requests[1]))
        #expect(sent.count == 4)
        #expect(sent[0]["role"] == .string("system"))
        #expect(sent[1]["role"] == .string("user"))
        #expect(sent[2]["role"] == .string("assistant"))
        // 只调工具时 content 为 null —— 这里的实现是整个字段省掉。
        #expect(sent[2]["content"] == nil)
        #expect(sent[2]["tool_calls"]?[0]?["id"] == .string("call_1"))
        // arguments 必须是**字符串**，不是对象。
        #expect(sent[2]["tool_calls"]?[0]?["function"]?["arguments"]
            == .string(#"{"city":"上海"}"#))
        #expect(sent[3]["role"] == .string("tool"))
        #expect(sent[3]["tool_call_id"] == .string("call_1"))
        #expect(sent[3]["content"] == .string("上海 25 度"))
        // spec v2.3.0 的 tool 消息里没有 name 字段，不发。
        #expect(sent[3]["name"] == nil)
    }

    @Test("并行工具调用：一条响应里两个 call，各回一条 tool 消息")
    func parallelToolCalls() async throws {
        let spy = Spy()
        let server = try StubHTTPServer(replies: [
            .json(body: StubHTTPServer.openAIToolCallResponse([
                .init(id: "call_a", name: "get_weather", argumentPieces: [#"{"city":"广州"}"#]),
                .init(id: "call_b", name: "get_time", argumentPieces: ["{}"]),
            ])),
            .json(body: StubHTTPServer.openAIResponse(content: "广州 25 度，现在 12:00。")),
        ])
        defer { server.stop() }

        let provider = makeProvider(
            server, tools: ToolRegistry([weatherTool(spy), timeTool(spy)]))
        let response = try await provider.respond(to: ModelRequest(prompt: "广州天气和时间"))

        #expect(response.toolInvocations.map(\.id) == ["call_a", "call_b"])
        #expect(spy.seen.sorted() == ["time:{}", "广州"])
        // 没给 systemInstructions：user + assistant + 两条 tool。
        let sent = messages(try body(server.requests[1]))
        #expect(sent.count == 4)
        #expect(sent[1]["tool_calls"].map { value -> Int in
            if case .array(let items) = value { return items.count } else { return 0 }
        } == 2)
        #expect(sent[2]["role"] == .string("tool"))
        #expect(sent[2]["tool_call_id"] == .string("call_a"))
        #expect(sent[2]["content"] == .string("广州 25 度"))
        #expect(sent[3]["tool_call_id"] == .string("call_b"))
        #expect(sent[3]["content"] == .string("12:00"))
    }

    /// 少一条 tool 消息会让请求非法，所以「模型点了个不存在的工具」也必须回一条。
    @Test("未知工具：照样回一条 tool 消息，内容是错误说明")
    func unknownToolStillReplies() async throws {
        let server = try StubHTTPServer(replies: [
            .json(body: StubHTTPServer.openAIToolCallResponse([
                .init(id: "call_x", name: "launch_missile", argumentPieces: ["{}"])
            ])),
            .json(body: StubHTTPServer.openAIResponse(content: "我没有那个能力。")),
        ])
        defer { server.stop() }

        let provider = makeProvider(server, tools: ToolRegistry([weatherTool(Spy())]))
        let response = try await provider.respond(to: ModelRequest(prompt: "发射"))

        #expect(response.text == "我没有那个能力。")
        #expect(response.toolInvocations.map(\.isError) == [true])
        let sent = messages(try body(server.requests[1]))
        #expect(sent.last?["role"] == .string("tool"))
        #expect(sent.last?["tool_call_id"] == .string("call_x"))
    }

    /// 云端的工具循环在客户端手里，模型可以永远要求调工具。每一轮都是一次真实计费请求，
    /// 所以必须有上限，且**如实报错**而不是把最后一轮的空回答当成答案。
    @Test("工具循环有上限：模型一直要求调工具就如实报错")
    func toolLoopLimit() async throws {
        let server = try StubHTTPServer(reply: .json(
            body: StubHTTPServer.openAIToolCallResponse([
                .init(id: "call_1", name: "get_weather", argumentPieces: [#"{"city":"A"}"#])
            ])))
        defer { server.stop() }

        let provider = makeProvider(
            server, tools: ToolRegistry([weatherTool(Spy())]), maximumToolIterations: 2)
        await #expect(throws: ModelError.toolLoopLimitExceeded(limit: 2)) {
            _ = try await provider.respond(to: ModelRequest(prompt: "循环"))
        }
        // 1 次首发 + 2 轮工具回传 = 3 次请求，第 3 次仍要工具就停。
        #expect(server.requests.count == 3)
    }

    /// `.required` 每轮都发就等于要求模型永远调工具，永远轮不到它给答案。
    @Test("强制类 tool_choice 只在第一轮下发")
    func toolChoiceOnlyOnFirstRound() async throws {
        let server = try StubHTTPServer(replies: [
            .json(body: StubHTTPServer.openAIToolCallResponse([
                .init(id: "call_1", name: "get_weather", argumentPieces: [#"{"city":"A"}"#])
            ])),
            .json(body: StubHTTPServer.openAIResponse(content: "完")),
        ])
        defer { server.stop() }

        let provider = makeProvider(server, tools: ToolRegistry([weatherTool(Spy())]))
        _ = try await provider.respond(
            to: ModelRequest(prompt: "天气", toolChoice: .specific("get_weather")))

        #expect(try body(server.requests[0])["tool_choice"]
            == .object(["type": .string("function"),
                        "function": .object(["name": .string("get_weather")])]))
        #expect(try body(server.requests[1])["tool_choice"] == nil)
        // 工具定义每轮都要带 —— 服务端不记状态。
        #expect(try body(server.requests[1])["tools"] != nil)
    }

    @Test("没有工具时整个 tools 字段省掉，不发空数组")
    func noToolsNoFields() async throws {
        let server = try StubHTTPServer(reply: .json(
            body: StubHTTPServer.openAIResponse(content: "你好")))
        defer { server.stop() }

        let provider = makeProvider(server, tools: .empty)
        _ = try await provider.respond(to: ModelRequest(prompt: "嗨", toolChoice: .required))

        let sent = try body(server.requests[0])
        #expect(sent["tools"] == nil)
        #expect(sent["tool_choice"] == nil)
    }

    @Test("关掉 strict：可选字段不进 required，也不发 strict 字段")
    func looseSchemaOnTheWire() async throws {
        let server = try StubHTTPServer(reply: .json(
            body: StubHTTPServer.openAIResponse(content: "好")))
        defer { server.stop() }

        let tool = AgentTool(
            name: "t", description: "", parameters: .object(
                name: "A", properties: [.init(name: "x", schema: .string(), isOptional: true)])
        ) { _ in "" }
        let provider = makeProvider(server, tools: ToolRegistry([tool]), strict: false)
        _ = try await provider.respond(to: ModelRequest(prompt: "嗨"))

        let function = try body(server.requests[0])["tools"]?[0]?["function"]
        #expect(function?["strict"] == nil)
        #expect(function?["parameters"]?["required"] == .array([]))
    }

    // MARK: - 流式

    @Test("流式闭环：工具轮不吐终片，最终回答按累积快照吐")
    func streamingRoundTrip() async throws {
        let spy = Spy()
        let server = try StubHTTPServer(replies: [
            .sse(
                frames: StubHTTPServer.openAIToolCallStreamFrames([
                    .init(
                        id: "call_1", name: "get_weather",
                        argumentPieces: [#"{"city":"#, #""深圳"}"#])
                ]),
                perFrameDelay: .milliseconds(5)),
            .sse(
                frames: StubHTTPServer.openAIStreamFrames(deltas: ["深圳", "今天", " 25 度"]),
                perFrameDelay: .milliseconds(5)),
        ])
        defer { server.stop() }

        let provider = makeProvider(server, tools: ToolRegistry([weatherTool(spy)]))
        var chunks: [ModelResponseChunk] = []
        for try await chunk in provider.streamResponse(to: ModelRequest(prompt: "深圳天气")) {
            chunks.append(chunk)
        }

        #expect(spy.seen == ["深圳"])
        #expect(server.requests.count == 2)
        // 工具轮**没有**产生终片 —— 否则 UI 会以为回答已经结束。
        #expect(chunks.filter(\.isFinal).count == 1)
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.map(\.cumulativeText) == ["深圳", "深圳今天", "深圳今天 25 度", "深圳今天 25 度"])
        // 快照不变量：每片都是前一片的延展。
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.cumulativeText.hasPrefix(previous.cumulativeText))
        }
    }

    @Test("流式并行工具调用：交错到达的分片按 index 各归各位")
    func streamingParallelToolCalls() async throws {
        let spy = Spy()
        let server = try StubHTTPServer(replies: [
            .sse(
                frames: StubHTTPServer.openAIToolCallStreamFrames([
                    .init(
                        index: 0, id: "call_a", name: "get_weather",
                        argumentPieces: [#"{"city":"#, #""杭州"}"#]),
                    .init(index: 1, id: "call_b", name: "get_time", argumentPieces: ["{", "}"]),
                ]),
                perFrameDelay: .milliseconds(2)),
            .sse(
                frames: StubHTTPServer.openAIStreamFrames(deltas: ["杭州 25 度，12:00"]),
                perFrameDelay: .zero),
        ])
        defer { server.stop() }

        let provider = makeProvider(
            server, tools: ToolRegistry([weatherTool(spy), timeTool(spy)]))
        var texts: [String] = []
        for try await chunk in provider.streamResponse(to: ModelRequest(prompt: "杭州")) {
            texts.append(chunk.cumulativeText)
        }

        #expect(spy.seen.sorted() == ["time:{}", "杭州"])
        let sent = messages(try body(server.requests[1]))
        #expect(sent.count == 4)
        #expect(sent[2]["tool_call_id"] == .string("call_a"))
        #expect(sent[3]["tool_call_id"] == .string("call_b"))
        #expect(texts.last == "杭州 25 度，12:00")
    }

    @Test("流式：边说边调工具时，已吐出的文字要保留在后续快照的前缀里")
    func streamingContentAlongsideToolCall() async throws {
        let spy = Spy()
        var firstRound = ["data: {\"choices\":[{\"delta\":{\"content\":\"我查一下。\"}}]}\n\n"]
        firstRound += StubHTTPServer.openAIToolCallStreamFrames([
            .init(id: "call_1", name: "get_weather", argumentPieces: [#"{"city":"苏州"}"#])
        ])
        let server = try StubHTTPServer(replies: [
            .sse(frames: firstRound, perFrameDelay: .milliseconds(2)),
            .sse(
                frames: StubHTTPServer.openAIStreamFrames(deltas: ["苏州 25 度。"]),
                perFrameDelay: .zero),
        ])
        defer { server.stop() }

        let provider = makeProvider(server, tools: ToolRegistry([weatherTool(spy)]))
        var chunks: [ModelResponseChunk] = []
        for try await chunk in provider.streamResponse(to: ModelRequest(prompt: "苏州天气")) {
            chunks.append(chunk)
        }

        #expect(chunks.map(\.cumulativeText) == ["我查一下。", "我查一下。苏州 25 度。", "我查一下。苏州 25 度。"])
        #expect(chunks.filter(\.isFinal).count == 1)
        // 这一轮的文字也要原样填回 assistant 消息，否则模型看不到自己说过什么。
        let sent = messages(try body(server.requests[1]))
        #expect(sent[1]["content"] == .string("我查一下。"))
        #expect(sent[1]["tool_calls"]?[0]?["id"] == .string("call_1"))
    }

    @Test("流式工具循环也有上限")
    func streamingToolLoopLimit() async throws {
        let server = try StubHTTPServer(reply: .sse(
            frames: StubHTTPServer.openAIToolCallStreamFrames([
                .init(id: "call_1", name: "get_weather", argumentPieces: [#"{"city":"A"}"#])
            ]),
            perFrameDelay: .zero))
        defer { server.stop() }

        let provider = makeProvider(
            server, tools: ToolRegistry([weatherTool(Spy())]), maximumToolIterations: 1)
        await #expect(throws: ModelError.toolLoopLimitExceeded(limit: 1)) {
            for try await _ in provider.streamResponse(to: ModelRequest(prompt: "循环")) {}
        }
        #expect(server.requests.count == 2)
    }
}

extension JSONValue {
    /// 只给测试用的数组下标。生产代码里没有按下标取 JSON 的需求，所以不放进主体。
    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}
