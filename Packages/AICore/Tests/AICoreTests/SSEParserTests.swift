import Foundation
import Testing

@testable import AICore

@Suite("SSE 解析器")
struct SSEParserTests {
    /// 把字符串按**字节**切成固定大小的片，模拟网络分片。
    private func byteChunks(_ text: String, size: Int) -> [[UInt8]] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: size).map {
            Array(bytes[$0..<min($0 + size, bytes.count)])
        }
    }

    private func parseAll(_ chunks: [[UInt8]]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks { events += parser.consume(chunk) }
        events += parser.finish()
        return events
    }

    @Test("基本事件：单行 data")
    func singleEvent() {
        let events = parseAll([Array("data: hello\n\n".utf8)])
        #expect(events == [SSEEvent(data: "hello")])
    }

    @Test("多行 data 用 \\n 连接")
    func multilineData() {
        let events = parseAll([Array("data: a\ndata: b\ndata: c\n\n".utf8)])
        #expect(events.count == 1)
        #expect(events.first?.data == "a\nb\nc")
    }

    @Test("只剥掉一个前导空格，后续空格属于内容")
    func singleLeadingSpaceOnly() {
        let events = parseAll([Array("data:   x\n\n".utf8)])
        #expect(events.first?.data == "  x")
    }

    @Test("没有冒号的行是字段名，值为空")
    func fieldWithoutColon() {
        let events = parseAll([Array("data\ndata: tail\n\n".utf8)])
        #expect(events.first?.data == "\ntail")
    }

    @Test("冒号开头的注释行被忽略（服务端心跳）")
    func commentIsIgnored() {
        let text = ": keep-alive\ndata: real\n\n: another\n\n"
        let events = parseAll([Array(text.utf8)])
        #expect(events == [SSEEvent(data: "real")])
    }

    @Test("event / id / retry 字段")
    func metadataFields() {
        let text = "event: delta\nid: 42\nretry: 3000\ndata: x\n\n"
        let events = parseAll([Array(text.utf8)])
        #expect(events == [SSEEvent(type: "delta", data: "x", id: "42", retry: 3000)])
    }

    @Test("retry 非纯数字时整个字段被忽略")
    func invalidRetryIgnored() {
        let events = parseAll([Array("retry: 3s\ndata: x\n\n".utf8)])
        #expect(events.first?.retry == nil)
    }

    @Test("id 跨事件粘连，event 不粘连")
    func idStickyEventNot() {
        let text = "event: a\nid: 1\ndata: first\n\ndata: second\n\n"
        let events = parseAll([Array(text.utf8)])
        #expect(events.count == 2)
        #expect(events[0].type == "a")
        // event 必须被重置，否则第二个事件会错误继承类型
        #expect(events[1].type == nil)
        // id 按规范沿用
        #expect(events[1].id == "1")
    }

    @Test("data 为空的块不产生事件，但不能把 event 泄漏给下一个")
    func emptyDataProducesNoEvent() {
        let events = parseAll([Array("event: ghost\n\ndata: real\n\n".utf8)])
        #expect(events == [SSEEvent(data: "real")])
    }

    @Test("CRLF / CR / LF 三种行分隔符都认")
    func allLineTerminators() {
        #expect(parseAll([Array("data: a\r\n\r\n".utf8)]).first?.data == "a")
        #expect(parseAll([Array("data: b\r\r".utf8)]).first?.data == "b")
        #expect(parseAll([Array("data: c\n\n".utf8)]).first?.data == "c")
    }

    /// 这是整个解析器存在的理由。
    @Test("UTF-8 多字节字符被分片切断后仍能正确还原")
    func utf8SplitAcrossChunks() {
        let text = "data: 中文汉字与 emoji 🎉\n\n"
        // 逐字节喂：每个汉字 3 字节、emoji 4 字节，必然被切断
        let events = parseAll(byteChunks(text, size: 1))
        #expect(events.count == 1)
        #expect(events.first?.data == "中文汉字与 emoji 🎉")
    }

    @Test("任意分片大小下结果都与整体解析一致")
    func chunkSizeInvariant() {
        let text = "data: 第一片\n\nevent: x\ndata: 第二片🎉\ndata: 续行\n\n"
        let whole = parseAll([Array(text.utf8)])
        #expect(whole.count == 2)
        for size in 1...Array(text.utf8).count {
            #expect(parseAll(byteChunks(text, size: size)) == whole,
                    "分片大小 \(size) 的解析结果与整体不一致")
        }
    }

    @Test("末尾孤立 CR 被留住，等到下一片才判断是否 CRLF")
    func danglingCRHeldBack() {
        var parser = SSEParser()
        // 第一片以 CR 结束：此时还不知道是 CR 分隔符还是 CRLF 的前半
        #expect(parser.consume(Array("data: x\r".utf8)).isEmpty)
        // 补上 LF 后应当只算一个分隔符，不能算两个（否则会误派发）
        let events = parser.consume(Array("\n\r\n".utf8))
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test("流末尾缺少空行时仍派发最后一个事件")
    func finishFlushesIncompleteEvent() {
        var parser = SSEParser()
        #expect(parser.consume(Array("data: last\n".utf8)).isEmpty)
        // 真实服务端常直接关连接不补空行。规范说丢弃，我们选择补派发。
        #expect(parser.finish() == [SSEEvent(data: "last")])
    }

    @Test("流末尾连换行都没有时也派发")
    func finishFlushesUnterminatedLine() {
        var parser = SSEParser()
        _ = parser.consume(Array("data: no-newline".utf8))
        #expect(parser.finish() == [SSEEvent(data: "no-newline")])
    }

    @Test("开头 BOM 被剥掉，且逐字节喂入时也能正确识别")
    func bomStripped() {
        let withBOM = [0xEF, 0xBB, 0xBF] as [UInt8] + Array("data: x\n\n".utf8)
        #expect(parseAll([withBOM]).first?.data == "x")
        #expect(parseAll(withBOM.map { [$0] }).first?.data == "x")
    }

    @Test("BOM 只在流开头剥一次，中途出现的同样字节不动")
    func bomOnlyAtStart() {
        let text = "data: a\n\n"
        let bomBytes = String(decoding: [0xEF, 0xBB, 0xBF] as [UInt8], as: UTF8.self)
        let second = "data: \(bomBytes)b\n\n"
        let events = parseAll([Array(text.utf8), Array(second.utf8)])
        #expect(events.count == 2)
        #expect(events[1].data == "\(bomBytes)b")
    }

    @Test("空流不产生事件")
    func emptyStream() {
        var parser = SSEParser()
        #expect(parser.consume([]).isEmpty)
        #expect(parser.finish().isEmpty)
    }
}
