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

    private func drainStream(
        _ request: ModelRequest,
        into continuation: AsyncThrowingStream<ModelResponseChunk, any Error>.Continuation
    ) async throws {
        let urlRequest = try await makeURLRequest(for: request, stream: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudFailureMapper.modelError(
                status: http.statusCode,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                body: try await Self.collectErrorBody(from: bytes)
            )
        }

        var parser = SSEParser()
        var accumulated = ""
        var scratch: [UInt8] = []

        for try await byte in bytes {
            try Task.checkCancellation()
            scratch.append(byte)
            // 遇到换行立刻冲刷。SSE 的事件边界是空行，按行冲刷能让首 token 最快到 UI；
            // 4096 的上限只是防御一个不吐换行的坏服务端把内存吃光。
            guard byte == 0x0A || scratch.count >= 4096 else { continue }
            let events = parser.consume(scratch)
            scratch.removeAll(keepingCapacity: true)
            if try Self.forward(events, into: continuation, accumulated: &accumulated) {
                return
            }
        }

        if !scratch.isEmpty,
           try Self.forward(parser.consume(scratch), into: continuation,
                            accumulated: &accumulated) {
            return
        }
        if try Self.forward(parser.finish(), into: continuation, accumulated: &accumulated) {
            return
        }

        // 服务端没送 `[DONE]` 就把连接关了。补一个终片 ——
        // 否则 UI 会永远停在「正在回答」，而实际上已经没有后续了。
        continuation.yield(ModelResponseChunk(cumulativeText: accumulated, isFinal: true))
    }

    /// 把一批 SSE 事件转成快照片。返回 true 表示流已终止（收到 `[DONE]`）。
    private static func forward(
        _ events: [SSEEvent],
        into continuation: AsyncThrowingStream<ModelResponseChunk, any Error>.Continuation,
        accumulated: inout String
    ) throws -> Bool {
        for event in events {
            if event.data == CloudWire.doneSentinel {
                continuation.yield(
                    ModelResponseChunk(cumulativeText: accumulated, isFinal: true)
                )
                return true
            }

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

            // 首帧通常只带 role 不带 content，空片没有信息量，不往下吐。
            guard let delta = choice?.delta?.content, !delta.isEmpty else { continue }
            accumulated += delta
            continuation.yield(
                ModelResponseChunk(cumulativeText: accumulated, isFinal: false)
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
