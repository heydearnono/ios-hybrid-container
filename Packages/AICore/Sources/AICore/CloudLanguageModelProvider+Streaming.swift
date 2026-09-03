import Foundation

extension CloudLanguageModelProvider {
    /// 流式响应。
    ///
    /// **云端吐的是增量 delta，本项目的协议要求累积快照** —— 转换就在这里做。
    /// 方向是「增量累加成快照」而不是「快照做 diff 成增量」：前者无损，后者一旦模型
    /// 修订前文就会产出错误结果。依据见 `ModelResponseChunk` 的注释。
    public nonisolated func streamResponse(
        to request: ModelRequest
    ) -> AsyncThrowingStream<ModelResponseChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.drainStream(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: CloudFailureMapper.modelError(
                            from: error, timeout: request.timeout
                        )
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    /// 一次流式请求全过程的可变状态。
    ///
    /// 打包成一个结构体而不是四个 `inout` 参数，是因为它们必须**同生共死**：
    /// 哪些跨轮保留、哪些每次尝试重置，是这段逻辑最容易写错的地方，集中在 `beginAttempt()`
    /// 一处比散在参数列表里可靠。
    struct StreamState {
        /// 跨轮累积、对下游可见的快照。工具轮通常不产生内容，但模型可以边说边调工具。
        var accumulated = ""
        /// 本次尝试内的 assistant 文本，回传给模型时要放进 assistant 消息。
        var roundText = ""
        /// 已经向下游吐过内容 → 禁止重连。见 `ReconnectPolicy`。
        var delivered = false
        var toolCalls = ToolCallAccumulator()

        /// 每次 HTTP 尝试开始时重置**本次尝试**的状态。
        ///
        /// 必须在这里重置而不是每轮重置：重连是重发整个请求，上一次尝试可能已经攒了半截
        /// 工具参数，不清掉就会把两次的参数字符串拼在一起。
        /// `accumulated` / `delivered` 则相反，必须跨尝试保留 —— 它们是「已经出门了」的事实。
        mutating func beginAttempt() {
            roundText = ""
            toolCalls = ToolCallAccumulator()
        }
    }

    /// 跑「请求 → 可能调工具 → 再请求」的循环，并按 `ReconnectPolicy` 处理每次请求的重发。
    ///
    /// **`delivered` 是重连这一侧的关键**：一旦有内容吐给了下游，就不允许再重连 ——
    /// 重发拿回的是一段全新文本，接不上已吐出的部分。理由详见 `ReconnectPolicy`。
    ///
    /// **工具循环这一侧的关键是 `maximumToolIterations`**：云端的循环在客户端手里，
    /// 没有上限就是个能烧钱的死循环。
    private func drainStream(
        _ request: ModelRequest,
        into continuation: AsyncThrowingStream<ModelResponseChunk, any Error>.Continuation
    ) async throws {
        var state = StreamState()
        var messages = Self.initialMessages(for: request)
        var roundsUsed = 0

        while true {
            let isFirstRound = roundsUsed == 0
            let round = try await reconnect.retrying(
                timeout: request.timeout,
                canRetry: { !state.delivered }
            ) {
                try await self.drainOnce(
                    request, messages: messages, isFirstRound: isFirstRound,
                    into: continuation, state: &state)
            }

            // 没有工具调用就说明这一轮是最终回答，终片已经在 `drainOnce` 里吐过了。
            guard !round.toolCalls.isEmpty else { return }
            guard roundsUsed < maximumToolIterations else {
                throw ModelError.toolLoopLimitExceeded(limit: maximumToolIterations)
            }
            roundsUsed += 1

            messages.append(.assistant(content: round.text, toolCalls: round.toolCalls))
            let results = await tools.execute(round.toolCalls)
            messages.append(contentsOf: results.map { CloudWire.Message.toolResult($0) })
        }
    }

    private func drainOnce(
        _ request: ModelRequest,
        messages: [CloudWire.Message],
        isFirstRound: Bool,
        into continuation: AsyncThrowingStream<ModelResponseChunk, any Error>.Continuation,
        state: inout StreamState
    ) async throws -> RoundOutcome {
        state.beginAttempt()
        let urlRequest = try await makeURLRequest(
            request, messages: messages, stream: true, isFirstRound: isFirstRound)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudFailureMapper.modelError(
                status: http.statusCode,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                body: try await Self.collectErrorBody(from: bytes)
            )
        }

        var parser = SSEParser()
        var scratch: [UInt8] = []
        var ended = false

        for try await byte in bytes {
            try Task.checkCancellation()
            scratch.append(byte)
            // 遇到换行立刻冲刷。SSE 的事件边界是空行，按行冲刷能让首 token 最快到 UI；
            // 4096 的上限只是防御一个不吐换行的坏服务端把内存吃光。
            guard byte == 0x0A || scratch.count >= 4096 else { continue }
            let events = parser.consume(scratch)
            scratch.removeAll(keepingCapacity: true)
            if try Self.forward(events, into: continuation, state: &state) {
                ended = true
                break
            }
        }

        if !ended, !scratch.isEmpty {
            ended = try Self.forward(parser.consume(scratch), into: continuation, state: &state)
        }
        if !ended {
            _ = try Self.forward(parser.finish(), into: continuation, state: &state)
        }

        let toolCalls = try state.toolCalls.finish()
        if toolCalls.isEmpty {
            // 终片。服务端没送 `[DONE]` 就关连接时也要补一个 ——
            // 否则 UI 会永远停在「正在回答」，而实际上已经没有后续了。
            continuation.yield(
                ModelResponseChunk(cumulativeText: state.accumulated, isFinal: true))
        }
        return RoundOutcome(
            text: state.roundText.isEmpty ? nil : state.roundText, toolCalls: toolCalls)
    }

    /// 把一批 SSE 事件转成快照片，并顺手拼接工具调用分片。
    /// 返回 true 表示流已终止（收到 `[DONE]`）。
    ///
    /// **终片不在这里吐** —— 收到 `[DONE]` 时还不知道这一轮是最终回答还是工具轮，
    /// 由 `drainOnce` 拿到完整工具调用列表之后再决定。
    private static func forward(
        _ events: [SSEEvent],
        into continuation: AsyncThrowingStream<ModelResponseChunk, any Error>.Continuation,
        state: inout StreamState
    ) throws -> Bool {
        for event in events {
            if event.data == CloudWire.doneSentinel { return true }

            let chunk: CloudWire.ChatStreamChunk
            do {
                chunk = try JSONDecoder().decode(
                    CloudWire.ChatStreamChunk.self, from: Data(event.data.utf8)
                )
            } catch {
                // 这里刻意不静默跳过无法解析的帧：吞掉它等于把服务端的问题变成
                // 「回答莫名少了一段」，排查成本极高。宁可显式失败。
                throw ModelError.decodingFailure(
                    detail: "无法解析流式帧：\(CloudFailureMapper.truncate(event.data))"
                )
            }

            if let payload = chunk.error {
                throw CloudLanguageModelProvider.modelError(fromPayload: payload)
            }

            let choice = chunk.choices?.first
            if let reason = choice?.finish_reason,
               CloudWire.contentFilterFinishReasons.contains(reason) {
                throw ModelError.guardrailViolation
            }

            if let calls = choice?.delta?.tool_calls, !calls.isEmpty {
                state.toolCalls.consume(calls)
            }

            // 首帧通常只带 role 不带 content，空片没有信息量，不往下吐。
            guard let delta = choice?.delta?.content, !delta.isEmpty else { continue }
            state.accumulated += delta
            state.roundText += delta
            // 一旦有内容出门，重连就被禁掉了 —— 见 `ReconnectPolicy`。
            state.delivered = true
            continuation.yield(
                ModelResponseChunk(cumulativeText: state.accumulated, isFinal: false)
            )
        }
        return false
    }

    /// 非 2xx 时把响应体读出来，好让错误信息可诊断。有上限，防止服务端返回整页 HTML。
    private static func collectErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body: [UInt8] = []
        for try await byte in bytes {
            body.append(byte)
            if body.count >= CloudFailureMapper.bodyLimit * 4 { break }
        }
        return String(decoding: body, as: UTF8.self)
    }
}
