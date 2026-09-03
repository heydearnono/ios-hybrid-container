// spike: text-embedding-01 —— 「裸进程 vs 真 App」对照探针。
// 目的：simctl spawn 起的裸进程没有 App 容器，怀疑 NLContextualEmbedding 的
// "Embedding model requires compilation" 是因为它没地方写编译产物。
// 这个文件既能被 simctl spawn 跑，也能打包成 .app 用 simctl launch 跑，比对结果。

import Foundation
import NaturalLanguage

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

log("bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")")
log("NSHomeDirectory=\(NSHomeDirectory())")
log("NSTemporaryDirectory=\(NSTemporaryDirectory())")
let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
log("cachesDirectory=\(caches?.path ?? "nil")")
if let c = caches {
    let probe = c.appendingPathComponent("nl-write-probe.txt")
    do {
        try "ok".write(to: probe, atomically: true, encoding: .utf8)
        log("caches writable: YES")
        try? FileManager.default.removeItem(at: probe)
    } catch {
        log("caches writable: NO (\(error))")
    }
}

guard let e = NLContextualEmbedding(language: .simplifiedChinese) else {
    log("NLContextualEmbedding(language: .simplifiedChinese) = nil")
    exit(0)
}
log("id=\(e.modelIdentifier) dim=\(e.dimension) maxSeqLen=\(e.maximumSequenceLength) hasAvailableAssets=\(e.hasAvailableAssets)")

for attempt in 1...3 {
    do {
        try e.load()
        log("attempt \(attempt): load() OK")
        let r = try e.embeddingResult(for: "今天天气真好", language: .simplifiedChinese)
        log("attempt \(attempt): embeddingResult seqLen=\(r.sequenceLength) lang=\(r.language.rawValue)")
        var n = 0
        var dim = 0
        r.enumerateTokenVectors(in: r.string.startIndex..<r.string.endIndex) { v, _ in
            n += 1; dim = v.count; return true
        }
        log("attempt \(attempt): tokenVectors=\(n) dim=\(dim)")
        e.unload()
        exit(0)
    } catch {
        log("attempt \(attempt): load() FAILED: \(error)")
    }
    // 等一会儿，看后台编译会不会完成
    Thread.sleep(forTimeInterval: 20)
}

log("load() 连续 3 次失败（每次间隔 20s）")
exit(0)
