import Foundation

/// 一个 Server-Sent Events 事件。
///
/// 字段命名跟随 SSE 规范（`event:` / `data:` / `id:` / `retry:`），
/// 但 `event` 在 Swift 里会和类型名混淆，故改称 `type`。
public struct SSEEvent: Sendable, Equatable {
    /// `event:` 字段。缺省时为 nil（规范里等价于 `"message"`）。
    public var type: String?
    /// `data:` 字段。多行 `data:` 按规范用 `\n` 连接。
    public var data: String
    /// `id:` 字段。**跨事件粘连** —— 一旦出现就沿用到被下一个 `id:` 覆盖为止。
    public var id: String?
    /// `retry:` 字段（毫秒）。同样跨事件粘连。
    public var retry: Int?

    public init(type: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.type = type
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// 增量 SSE 解析器。**按字节喂入，按事件吐出。**
///
/// 为什么不能用 `String(data:encoding:)` 逐片解码后按行切：
/// 网络分片边界会落在 UTF-8 多字节序列中间。一个汉字 3 字节，被切成 2+1 时，
/// 对前 2 字节调 `String(data:encoding:.utf8)` 返回 nil，那一片就整个丢了。
/// 所以未完成的行必须以**字节**形式留在缓冲区，只在拿到完整行之后才解码。
///
/// 行分隔符按规范同时接受 CRLF / LF / CR。缓冲区末尾的孤立 CR 会被留住不处理 ——
/// 它可能是尚未收全的 CRLF 的前半。
///
/// 这个类型是 SSE 层，**不认识任何厂商语义**：`[DONE]` 之类的哨兵值由上层
/// （`CloudLanguageModelProvider`）判断。
public struct SSEParser: Sendable {
    private static let lf: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 尚未构成完整行的字节。
    private var pending: [UInt8] = []
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastEventID: String?
    private var retry: Int?
    private var checkedBOM = false

    public init() {}

    /// 喂入一片字节，返回这一片促成的所有完整事件（可能为空，也可能多个）。
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        pending.append(contentsOf: bytes)
        stripBOMIfPossible()

        var events: [SSEEvent] = []
        var cursor = 0

        while let breakIndex = nextLineBreak(from: cursor) {
            let terminatorLength = terminatorLength(at: breakIndex)
            // 末尾孤立 CR：可能是 CRLF 的前半，留到下一片再判断。
            guard terminatorLength > 0 else { break }

            let line = decode(pending[cursor..<breakIndex])
            handle(line: line, into: &events)
            cursor = breakIndex + terminatorLength
        }

        if cursor > 0 { pending.removeFirst(cursor) }
        return events
    }

    /// 流结束时调用，吐出缓冲区里剩下的东西。
    ///
    /// **这里有意偏离规范。** SSE 规范要求丢弃末尾没有以空行结尾的不完整事件。
    /// 但真实服务端经常在最后一帧之后直接关连接，不补那个空行 ——
    /// 严格照规范做会丢掉最后一个 token。丢数据比偏离规范更糟，所以这里补一次派发。
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []

        if !pending.isEmpty {
            var tail = pending
            pending = []
            // 末尾可能留着一个孤立 CR，它是分隔符而不是内容。
            if tail.last == Self.cr { tail.removeLast() }
            if !tail.isEmpty { handle(line: decode(tail), into: &events) }
        }

        if let event = dispatch() { events.append(event) }
        return events
    }

    // MARK: - 字节层

    private mutating func stripBOMIfPossible() {
        guard !checkedBOM else { return }
        if pending.count >= Self.bom.count {
            if Array(pending.prefix(Self.bom.count)) == Self.bom {
                pending.removeFirst(Self.bom.count)
            }
            checkedBOM = true
        } else if !Self.bom.starts(with: pending) {
            checkedBOM = true // 已经能确定不是 BOM
        }
        // 否则字节还不够判断，等下一片
    }

    private func nextLineBreak(from cursor: Int) -> Int? {
        var index = cursor
        while index < pending.count {
            if pending[index] == Self.lf || pending[index] == Self.cr { return index }
            index += 1
        }
        return nil
    }

    /// 返回分隔符长度；0 表示「现在还判断不了」（末尾孤立 CR）。
    private func terminatorLength(at index: Int) -> Int {
        guard pending[index] == Self.cr else { return 1 } // LF
        guard index + 1 < pending.count else { return 0 } // CR 在末尾，可能是 CRLF 前半
        return pending[index + 1] == Self.lf ? 2 : 1
    }

    /// 行内不可能出现被截断的多字节序列（UTF-8 续字节都 ≥ 0x80，不会等于 CR/LF），
    /// 所以到这一步解码总能成功；真遇到非法字节则按替换字符处理，不丢整行。
    private func decode(_ bytes: some Sequence<UInt8>) -> String {
        let array = Array(bytes)
        return String(decoding: array, as: UTF8.self)
    }

    // MARK: - 字段层

    private mutating func handle(line: String, into events: inout [SSEEvent]) {
        if line.isEmpty {
            if let event = dispatch() { events.append(event) }
            return
        }
        // 以冒号开头是注释。服务端常用 `: keep-alive` 做心跳，必须静默吃掉。
        if line.hasPrefix(":") { return }

        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var raw = line[line.index(after: colon)...]
            // 规范只允许剥掉**一个**前导空格，后续空格属于内容。
            if raw.first == " " { raw = raw.dropFirst() }
            value = String(raw)
        } else {
            // 没有冒号的整行是字段名，值为空字符串。
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            dataLines.append(value)
        case "id":
            // 规范：含 NUL 的 id 要忽略。
            if !value.contains("\0") { lastEventID = value }
        case "retry":
            // 规范：必须是 ASCII 数字，否则忽略整个字段。
            if !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) {
                retry = Int(value)
            }
        default:
            break // 未知字段按规范忽略
        }
    }

    /// 派发一个事件并重置逐事件状态。
    ///
    /// `data` 为空时按规范**不产生事件**，但 `event:` 仍要被清掉 ——
    /// 否则一个只有 `event:` 的空块会把类型泄漏给下一个事件。
    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataLines = []
            eventType = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(
            type: eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID,
            retry: retry
        )
    }
}
