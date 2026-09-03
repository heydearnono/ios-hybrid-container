import Foundation
import Network

/// 测试用的本地 HTTP/1.1 服务器。
///
/// 存在的理由：`CloudLanguageModelProvider` 的价值在于走**真实**的 `URLSession`、真实 socket、
/// 真实 SSE 字节流。用 `URLProtocol` 打桩能让测试更快，但那样绕过了整个网络栈，
/// 恰好把最容易出错的部分（分片边界、连接关闭时机、状态码处理）跳过了。
///
/// **只绑 127.0.0.1**：既是隔离，也是为了不触发 macOS 防火墙的「是否允许接受传入连接」弹窗
/// —— 那个弹窗需要人点，会直接破坏「机器无人工干预地验证」这条硬约束。
final class StubHTTPServer: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
        /// 请求头名大小写不敏感。
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    enum Reply: Sendable {
        /// 一次性完整响应（带 Content-Length）。
        case complete(status: Int, contentType: String, body: String, headers: [String: String])
        /// SSE：按帧推送，帧之间可插延迟；末尾关连接。
        case sse(frames: [String], perFrameDelay: Duration)
        /// 原始字节按给定切分推送。用来把 UTF-8 多字节序列切在分片边界上。
        case rawChunks(_ chunks: [[UInt8]], perChunkDelay: Duration)
        /// 声明了 `Content-Length` 却只发一部分就关连接。
        ///
        /// 这是模拟「流中途断线」的可靠办法：不带 `Content-Length` 的响应靠关连接界定结束，
        /// 提前关等于正常收尾，`URLSession` 不会报错；声明了长度却不给够，才是明确的截断。
        case truncated(declaredLength: Int, pieces: [String], perPieceDelay: Duration)
        /// 接受连接后什么都不回，也不关。用来验证超时保护。
        case hang

        static func json(status: Int = 200, body: String,
                         headers: [String: String] = [:]) -> Reply {
            .complete(status: status, contentType: "application/json",
                      body: body, headers: headers)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "StubHTTPServer")
    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    /// 第 N 个连接用 `replies[N]`；用完最后一个之后就一直重复它。
    /// 这样才能测「先失败几次、后成功」的重试路径。
    private let replies: [Reply]
    private var _connectionCount = 0

    /// 系统分配的端口。给了默认值，好让 `self` 在装回调之前就完成初始化 ——
    /// 回调必须在 `start()` **之前**装好（见 init 里的注释）。
    private(set) var port: UInt16 = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    convenience init(reply: Reply) throws {
        try self.init(replies: [reply])
    }

    init(replies: [Reply]) throws {
        precondition(!replies.isEmpty)
        self.replies = replies

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 强制只监听回环地址，端口交给系统分配（避免测试并发时抢端口）。
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        // **必须在 start() 之前装好 newConnectionHandler。** 装晚了 listener 会拒掉先到的
        // 连接，客户端表现为 `-1004 Could not connect to the server` —— 排查起来很像
        // 端口没绑上，其实是回调时序问题。
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success,
              let assigned = listener.port?.rawValue
        else {
            listener.cancel()
            throw StubServerError.failedToStart
        }
        port = assigned
    }

    func stop() {
        listener.cancel()
    }

    enum StubServerError: Error { case failedToStart }
}

// MARK: - 连接处理

extension StubHTTPServer {
    private func accept(_ connection: NWConnection) {
        lock.lock()
        let index = _connectionCount
        _connectionCount += 1
        lock.unlock()

        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data(), replyIndex: index)
    }

    /// 递归读取，直到攒够 header 加 `Content-Length` 指定的 body。
    private func readRequest(on connection: NWConnection, buffer: Data, replyIndex: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let parsed = Self.parseRequest(buffer) {
                self.lock.lock()
                self._requests.append(parsed)
                self.lock.unlock()
                self.respond(on: connection, replyIndex: replyIndex)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.readRequest(on: connection, buffer: buffer, replyIndex: replyIndex)
        }
    }

    /// 返回 nil 表示还没收全。
    private static func parseRequest(_ buffer: Data) -> RecordedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }

        let headerText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let body = buffer[range.upperBound...]
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        guard body.count >= expected else { return nil }

        return RecordedRequest(
            method: parts[0], path: parts[1], headers: headers, body: Data(body)
        )
    }
}

// MARK: - 应答

extension StubHTTPServer {
    private func respond(on connection: NWConnection, replyIndex: Int) {
        switch replies[min(replyIndex, replies.count - 1)] {
        case .hang:
            break // 故意不回、不关：让客户端自己超时

        case .complete(let status, let contentType, let body, let extra):
            let payload = Data(body.utf8)
            var headers = extra
            headers["Content-Type"] = contentType
            headers["Content-Length"] = String(payload.count)
            let head = Self.responseHead(status: status, headers: headers)
            send([head + payload], on: connection, delay: .zero)

        case .sse(let frames, let delay):
            let head = Self.responseHead(
                status: 200,
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
            )
            send([head] + frames.map { Data($0.utf8) }, on: connection, delay: delay)

        case .rawChunks(let chunks, let delay):
            let head = Self.responseHead(
                status: 200,
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
            )
            send([head] + chunks.map { Data($0) }, on: connection, delay: delay)

        case .truncated(let declaredLength, let pieces, let delay):
            // 声明的长度故意大于实际发送量，发完就关 —— 客户端会看到一个明确的截断错误。
            let head = Self.responseHead(
                status: 200,
                headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "Content-Length": String(declaredLength),
                ]
            )
            send([head] + pieces.map { Data($0.utf8) }, on: connection, delay: delay)
        }
    }

    /// 不带 `Content-Length` 时用 `Connection: close` 界定响应结束 —— HTTP/1.1 允许，
    /// `URLSession` 也认。SSE 就是靠这个收尾的。
    private static func responseHead(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }

    /// 顺序发送各片，片间插延迟；最后一片带 `isComplete` 以关闭连接。
    private func send(_ pieces: [Data], on connection: NWConnection, delay: Duration) {
        guard !pieces.isEmpty else {
            connection.send(content: nil, isComplete: true, completion: .idempotent)
            return
        }
        var remaining = pieces
        let piece = remaining.removeFirst()
        let rest = remaining
        let isLast = rest.isEmpty

        connection.send(content: piece, isComplete: isLast, completion: .contentProcessed {
            [weak self] error in
            guard let self, error == nil, !isLast else {
                connection.cancel()
                return
            }
            let deadline = DispatchTime.now() + .nanoseconds(Int(delay.nanoseconds))
            self.queue.asyncAfter(deadline: deadline) {
                self.send(rest, on: connection, delay: delay)
            }
        })
    }
}

extension Duration {
    var nanoseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }
}

// MARK: - 便利构造

extension StubHTTPServer {
    /// 最小 JSON 字符串转义。不用 `JSONEncoder` 是因为顶层裸字符串（fragment）的编码
    /// 在不同 Foundation 版本上行为不一致，测试辅助代码不该踩这种坑。
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    /// 把一串文本增量包装成 OpenAI 兼容的 SSE 帧序列，末尾补 `[DONE]`。
    static func openAIStreamFrames(deltas: [String], finishReason: String? = "stop") -> [String] {
        var frames = deltas.map { delta in
            "data: {\"choices\":[{\"delta\":{\"content\":\(jsonString(delta))}}]}\n\n"
        }
        if let finishReason {
            frames.append(
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(finishReason)\"}]}\n\n"
            )
        }
        frames.append("data: [DONE]\n\n")
        return frames
    }

    static func openAIResponse(content: String, finishReason: String = "stop") -> String {
        """
        {"choices":[{"message":{"role":"assistant","content":\(jsonString(content))},\
        "finish_reason":"\(finishReason)"}]}
        """
    }

    /// 一次工具调用的描述。`argumentPieces` 分片是为了模拟流式逐帧追加。
    struct StubToolCall: Sendable {
        var index: Int
        var id: String
        var name: String
        var argumentPieces: [String]

        init(index: Int = 0, id: String, name: String, argumentPieces: [String]) {
            self.index = index
            self.id = id
            self.name = name
            self.argumentPieces = argumentPieces
        }

        var arguments: String { argumentPieces.joined() }
    }

    /// 非流式的 `tool_calls` 响应。`content` 为 `null`，`finish_reason` 为 `tool_calls`。
    static func openAIToolCallResponse(_ calls: [StubToolCall]) -> String {
        let encoded = calls.map { call in
            """
            {"id":"\(call.id)","type":"function","function":\
            {"name":"\(call.name)","arguments":\(jsonString(call.arguments))}}
            """
        }
        return """
            {"choices":[{"message":{"role":"assistant","content":null,\
            "tool_calls":[\(encoded.joined(separator: ","))]},"finish_reason":"tool_calls"}]}
            """
    }

    /// 流式的工具调用帧序列。
    ///
    /// 刻意按真实形状构造：**首帧只带 `id` / `type` / `function.name`**，参数分片随后逐帧追加，
    /// 且多个调用的参数帧**按 `index` 交错**到达 —— 只认「当前工具调用」的实现会在这里翻车。
    static func openAIToolCallStreamFrames(
        _ calls: [StubToolCall], finishReason: String? = "tool_calls"
    ) -> [String] {
        var frames: [String] = []
        for call in calls {
            frames.append("""
                data: {"choices":[{"delta":{"tool_calls":[{"index":\(call.index),\
                "id":"\(call.id)","type":"function","function":\
                {"name":"\(call.name)","arguments":""}}]}}]}\n\n
                """)
        }
        let deepest = calls.map(\.argumentPieces.count).max() ?? 0
        for step in 0..<deepest {
            for call in calls where step < call.argumentPieces.count {
                frames.append("""
                    data: {"choices":[{"delta":{"tool_calls":[{"index":\(call.index),\
                    "function":{"arguments":\(jsonString(call.argumentPieces[step]))}}]}}]}\n\n
                    """)
            }
        }
        if let finishReason {
            frames.append(
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(finishReason)\"}]}\n\n"
            )
        }
        frames.append("data: [DONE]\n\n")
        return frames
    }
}
