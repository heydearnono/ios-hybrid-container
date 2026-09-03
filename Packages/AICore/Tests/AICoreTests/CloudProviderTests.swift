import Foundation
import Testing

@testable import AICore

@Suite("云端提供方（打本地 stub 服务器）")
struct CloudProviderTests {
    // MARK: - 脚手架

    private func makeProvider(
        _ server: StubHTTPServer,
        token: String? = "test-token"
    ) -> CloudLanguageModelProvider {
        CloudLanguageModelProvider(
            configuration: CloudProviderConfiguration(
                baseURL: server.baseURL, model: "test-model"
            ),
            credential: { token },
            session: URLSession(configuration: .ephemeral)
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<ModelResponseChunk, any Error>
    ) async throws -> [ModelResponseChunk] {
        var chunks: [ModelResponseChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    // MARK: - 非流式

    @Test("非流式：拿到回答，并且请求按预期构造")
    func nonStreamingRoundTrip() async throws {
        let server = try StubHTTPServer(
            reply: .json(body: StubHTTPServer.openAIResponse(content: "你好，我是助手。"))
        )
        defer { server.stop() }

        let provider = makeProvider(server)
        let response = try await provider.respond(
            to: ModelRequest(prompt: "你好", systemInstructions: "简洁作答", temperature: 0.3)
        )

        #expect(response.text == "你好，我是助手。")
        #expect(response.providerID == .cloud)

        let recorded = try #require(server.requests.first)
        #expect(recorded.method == "POST")
        #expect(recorded.path == "/v1/chat/completions")
        #expect(recorded.header("authorization") == "Bearer test-token")
        #expect(recorded.header("content-type") == "application/json")
        // 系统指令必须落在 messages 里，而不是被丢掉
        #expect(recorded.bodyText.contains("简洁作答"))
        #expect(recorded.bodyText.contains("\"stream\":false"))
        #expect(recorded.bodyText.contains("\"model\":\"test-model\""))
    }

    @Test("没有凭证时如实报不可用，且一个请求都不发")
    func missingCredentialShortCircuits() async throws {
        let server = try StubHTTPServer(reply: .json(body: "{}"))
        defer { server.stop() }

        let provider = makeProvider(server, token: nil)
        #expect(await provider.availability() == .unavailable(.notConfigured))

        await #expect(throws: ModelError.unavailable(.notConfigured)) {
            _ = try await provider.respond(to: ModelRequest(prompt: "x"))
        }
        // 明知会 401 还发出去，是白烧一次往返和一次计费。
        #expect(server.requests.isEmpty)
    }

    @Test("有凭证时 availability 为可用，且不发探测请求")
    func availabilityDoesNotProbe() async throws {
        let server = try StubHTTPServer(reply: .json(body: "{}"))
        defer { server.stop() }

        let provider = makeProvider(server)
        #expect(await provider.availability() == .available)
        #expect(server.requests.isEmpty)
    }

    // MARK: - 流式

    @Test("流式：delta 被累加成累积快照，末片 isFinal")
    func streamingAccumulatesSnapshots() async throws {
        let server = try StubHTTPServer(
            reply: .sse(
                frames: StubHTTPServer.openAIStreamFrames(deltas: ["你", "好", "世界"]),
                perFrameDelay: .zero
            )
        )
        defer { server.stop() }

        let chunks = try await collect(
            makeProvider(server).streamResponse(to: ModelRequest(prompt: "hi"))
        )

        #expect(chunks.map(\.cumulativeText) == ["你", "你好", "你好世界", "你好世界"])
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.dropLast().allSatisfy { !$0.isFinal })

        // 架构不变量：每片都必须是前一片的延展，UI 才能安全地直接赋值。
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.cumulativeText.hasPrefix(previous.cumulativeText))
        }
    }

    @Test("流式请求带 stream=true 与 SSE 的 Accept 头")
    func streamingRequestShape() async throws {
        let server = try StubHTTPServer(
            reply: .sse(frames: StubHTTPServer.openAIStreamFrames(deltas: ["x"]),
                        perFrameDelay: .zero)
        )
        defer { server.stop() }

        _ = try await collect(
            makeProvider(server).streamResponse(to: ModelRequest(prompt: "hi"))
        )
        let recorded = try #require(server.requests.first)
        #expect(recorded.bodyText.contains("\"stream\":true"))
        #expect(recorded.header("accept") == "text/event-stream")
    }

    /// 这条是整条流式链路的关键：真实网络分片不会体贴地落在字符边界上。
    @Test("流式：UTF-8 多字节字符被 TCP 分片切断仍能正确还原")
    func streamingSurvivesByteLevelSplits() async throws {
        let frames = StubHTTPServer.openAIStreamFrames(deltas: ["汉字", "🎉表情", "混合ab"])
        // 逐字节推送：每个汉字 3 字节、emoji 4 字节，必然被切断
        let singleBytes = Array(frames.joined().utf8).map { [$0] }

        let server = try StubHTTPServer(
            reply: .rawChunks(singleBytes, perChunkDelay: .zero)
        )
        defer { server.stop() }

        let chunks = try await collect(
            makeProvider(server).streamResponse(to: ModelRequest(prompt: "hi"))
        )
        #expect(chunks.last?.cumulativeText == "汉字🎉表情混合ab")
        #expect(chunks.last?.isFinal == true)
    }

    @Test("服务端没送 [DONE] 就关连接时，仍补一个终片")
    func missingDoneSentinelStillFinishes() async throws {
        // 只有一帧 delta，既无 finish_reason 也无 [DONE]，直接关连接
        let server = try StubHTTPServer(
            reply: .sse(frames: ["data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}\n\n"],
                        perFrameDelay: .zero)
        )
        defer { server.stop() }

        let chunks = try await collect(
            makeProvider(server).streamResponse(to: ModelRequest(prompt: "hi"))
        )
        // 少了终片，UI 会永远停在「正在回答」
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.last?.cumulativeText == "半句")
    }

    @Test("无法解析的流式帧显式失败，而不是静默跳过")
    func undecodableFrameFails() async throws {
        let server = try StubHTTPServer(
            reply: .sse(frames: ["data: 这不是 JSON\n\n"], perFrameDelay: .zero)
        )
        defer { server.stop() }

        let error = await #expect(throws: ModelError.self) {
            _ = try await self.collect(
                self.makeProvider(server).streamResponse(to: ModelRequest(prompt: "hi"))
            )
        }
        // 必须精确断言错误种类：只断言「抛了 ModelError」的话，连不上服务器
        // 也会让这条测试变绿 —— 那是假通过。
        guard case .decodingFailure = error else {
            Issue.record("期望 .decodingFailure，实际是 \(String(describing: error))")
            return
        }
    }
}
