// spike: text-embedding-01
// 问题：iOS 26.2 上有没有可用的「句向量」API 能做语义检索？
// 跑法见 README.md。日志一律写 stderr（stdout 走管道是块缓冲，被 kill 就什么都看不到）。

import Foundation
import NaturalLanguage

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func f(_ d: Double, _ digits: Int = 4) -> String {
    String(format: "%.\(digits)f", d)
}

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return Double.nan }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    }
    guard na > 0, nb > 0 else { return Double.nan }
    return dot / (na.squareRoot() * nb.squareRoot())
}

/// (关系标签, 句 A, 句 B)
let zhPairs: [(String, String, String)] = [
    ("近义", "今天天气真好", "今天的天气很不错"),
    ("近义", "怎么重置我的登录密码", "我忘记密码了要怎么办"),
    ("无关", "今天天气真好", "这台电脑的内存是十六个吉字节"),
    ("无关", "怎么重置我的登录密码", "红烧肉需要先炒糖色"),
    ("反义", "这家餐厅的菜非常好吃", "这家餐厅的菜非常难吃"),
    ("同词不同义", "他把桌上的苹果吃掉了", "苹果公司发布了新手机"),
]

let enPairs: [(String, String, String)] = [
    ("近义", "The weather is really nice today", "Today's weather is quite good"),
    ("无关", "The weather is really nice today", "This laptop has sixteen gigabytes of memory"),
    ("反义", "The food at this restaurant is delicious", "The food at this restaurant is terrible"),
]

// MARK: - [0] 各语言的 word / sentence embedding 到底存不存在

log("================ [0] NLEmbedding availability sweep ================")

let sweepLangs: [NLLanguage] = [
    .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
    .french, .german, .spanish, .italian, .portuguese, .russian, .arabic,
]

for lang in sweepLangs {
    let w = NLEmbedding.wordEmbedding(for: lang)
    let s = NLEmbedding.sentenceEmbedding(for: lang)
    let wDesc = w.map { "dim=\($0.dimension) vocab=\($0.vocabularySize)" } ?? "nil"
    let sDesc = s.map { "dim=\($0.dimension) vocab=\($0.vocabularySize)" } ?? "nil"
    log("  \(lang.rawValue): word=\(wDesc)  sentence=\(sDesc)  (wordRevs=\(NLEmbedding.supportedRevisions(for: lang).map { $0 }) sentRevs=\(NLEmbedding.supportedSentenceEmbeddingRevisions(for: lang).map { $0 }))")
}

// MARK: - [1] NLEmbedding：词向量 vs 句向量

log("")
log("================ [1] NLEmbedding ================")

let langs: [NLLanguage] = [.simplifiedChinese, .english]

for lang in langs {
    log("--- language = \(lang.rawValue) ---")

    let wordRevs = NLEmbedding.supportedRevisions(for: lang).map { $0 }
    log("supportedRevisions(word): \(wordRevs)  currentRevision: \(NLEmbedding.currentRevision(for: lang))")

    let sentRevs = NLEmbedding.supportedSentenceEmbeddingRevisions(for: lang).map { $0 }
    log("supportedSentenceEmbeddingRevisions: \(sentRevs)  currentSentenceEmbeddingRevision: \(NLEmbedding.currentSentenceEmbeddingRevision(for: lang))")

    // 词向量
    let t0 = Date()
    let word = NLEmbedding.wordEmbedding(for: lang)
    let wordLoad = Date().timeIntervalSince(t0)
    if let w = word {
        log("wordEmbedding: OK  dimension=\(w.dimension) vocabularySize=\(w.vocabularySize) revision=\(w.revision) load=\(f(wordLoad, 3))s")
    } else {
        log("wordEmbedding: nil (load=\(f(wordLoad, 3))s)")
    }

    // 句向量
    let t1 = Date()
    let sent = NLEmbedding.sentenceEmbedding(for: lang)
    let sentLoad = Date().timeIntervalSince(t1)
    guard let s = sent else {
        log("sentenceEmbedding: nil (load=\(f(sentLoad, 3))s) —— 该语言没有句向量模型")
        continue
    }
    log("sentenceEmbedding: OK  dimension=\(s.dimension) vocabularySize=\(s.vocabularySize) revision=\(s.revision) language=\(s.language?.rawValue ?? "nil") load=\(f(sentLoad, 3))s")

    let pairs = (lang == .simplifiedChinese) ? zhPairs : enPairs

    // 首次 vector(for:) 单独计时（冷启动）
    let firstText = pairs[0].1
    let t2 = Date()
    let firstVec = s.vector(for: firstText)
    let firstCall = Date().timeIntervalSince(t2)
    log("first vector(for:) -> \(firstVec == nil ? "nil" : "count=\(firstVec!.count)") in \(f(firstCall, 4))s")

    if let v = firstVec {
        let nonZero = v.contains { $0 != 0 }
        log("first vector all-zero? \(!nonZero)  head=\(v.prefix(6).map { f($0, 4) })")
    }

    // 计时：稳定态单次 vector(for:)
    var warm: [Double] = []
    for _ in 0..<10 {
        let t = Date()
        _ = s.vector(for: firstText)
        warm.append(Date().timeIntervalSince(t))
    }
    log("warm vector(for:) avg over 10 = \(f(warm.reduce(0,+) / Double(warm.count) * 1000, 3))ms")

    log("pair similarities (cos = 1 - NLDistance, 也用 vector 手算对照):")
    for (kind, a, b) in pairs {
        let dist = s.distance(between: a, and: b, distanceType: .cosine)
        let va = s.vector(for: a)
        let vb = s.vector(for: b)
        let manual = (va != nil && vb != nil) ? cosine(va!, vb!) : Double.nan
        log("  [\(kind)] cos=\(f(1.0 - dist)) (distance=\(f(dist))) manualCos=\(f(manual))  「\(a)」 vs 「\(b)」")
    }

    // 句向量对未登录/极端输入的行为
    for probe in ["", "asdkjhqwe zxcvbnm", "🙂🙂🙂"] {
        let v = s.vector(for: probe)
        log("  edge vector(for: \"\(probe)\") -> \(v == nil ? "nil" : "count=\(v!.count) allZero=\(!v!.contains { $0 != 0 })")")
    }

    // 句子长度上限：句向量对长文本是否还给结果
    let long = String(repeating: (lang == .simplifiedChinese ? "这是一段用来测试长度上限的中文文本。" : "This is a sentence used to test the length limit. "), count: 40)
    let lv = s.vector(for: long)
    log("  long input (\(long.count) chars) -> \(lv == nil ? "nil" : "count=\(lv!.count)")")
}

// MARK: - [2] NLContextualEmbedding 目录

log("")
log("================ [2] NLContextualEmbedding catalog ================")

let all = NLContextualEmbedding.contextualEmbeddings(forValues: [:])
log("contextualEmbeddings(forValues: [:]) count = \(all.count)   <- 空字典查不出东西")

let byRev = NLContextualEmbedding.contextualEmbeddings(forValues: [.revision: 1])
log("contextualEmbeddings(forValues: [.revision: 1]) count = \(byRev.count)")
for e in byRev {
    log("  id=\(e.modelIdentifier) rev=\(e.revision) dim=\(e.dimension) maxSeqLen=\(e.maximumSequenceLength) hasAvailableAssets=\(e.hasAvailableAssets)")
    log("    languages(\(e.languages.count))=\(e.languages.map { $0.rawValue }.sorted())")
    log("    scripts(\(e.scripts.count))=\(e.scripts.map { $0.rawValue }.sorted())")
}

let byScript = NLContextualEmbedding.contextualEmbeddings(forValues: [.scripts: [NLScript.simplifiedChinese.rawValue]])
log("query by scripts=[Hans] -> \(byScript.map { $0.modelIdentifier })")

let byLang = NLContextualEmbedding.contextualEmbeddings(forValues: [.languages: [NLLanguage.simplifiedChinese.rawValue]])
log("query by languages=[zh-Hans] -> \(byLang.map { $0.modelIdentifier })")

// 每个脚本各查一次，看总共有几个模型、覆盖哪些脚本
var idToScripts: [String: [String]] = [:]
let allScripts: [NLScript] = [
    .latin, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .cyrillic,
    .arabic, .hebrew, .greek, .devanagari, .thai, .tamil, .telugu, .bengali,
    .armenian, .georgian, .ethiopic, .khmer, .lao, .myanmar, .mongolian, .tibetan,
    .gujarati, .gurmukhi, .kannada, .malayalam, .oriya, .sinhala,
    .cherokee, .canadianAboriginalSyllabics, .undetermined,
]
for sc in allScripts {
    let ms = NLContextualEmbedding.contextualEmbeddings(forValues: [.scripts: [sc.rawValue]])
    for m in ms {
        idToScripts[m.modelIdentifier, default: []].append(sc.rawValue)
    }
}
log("distinct model identifiers reachable by script query = \(idToScripts.count)")
for (id, scs) in idToScripts.sorted(by: { $0.key < $1.key }) {
    let m = NLContextualEmbedding(modelIdentifier: id)
    log("  \(id): dim=\(m?.dimension ?? -1) maxSeqLen=\(m?.maximumSequenceLength ?? -1) hasAssets=\(m?.hasAvailableAssets ?? false) langCount=\(m?.languages.count ?? -1) scripts=\(scs.sorted())")
    if let m { log("    languages=\(m.languages.map { $0.rawValue }.sorted())") }
}

// MARK: - [3] NLContextualEmbedding 实际加载与推理

log("")
log("================ [3] NLContextualEmbedding load + inference ================")

func meanPooled(_ result: NLContextualEmbeddingResult) -> [Double] {
    var sum: [Double] = []
    var n = 0
    result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vec, _ in
        if sum.isEmpty { sum = [Double](repeating: 0, count: vec.count) }
        if vec.count == sum.count {
            for i in 0..<vec.count { sum[i] += vec[i] }
            n += 1
        }
        return true
    }
    guard n > 0 else { return [] }
    return sum.map { $0 / Double(n) }
}

var assetRequestAttempted = false

func probeContextual(_ label: String, _ embedding: NLContextualEmbedding?, language: NLLanguage, pairs: [(String, String, String)]) {
    guard let e = embedding else {
        log("[\(label)] contextualEmbedding = nil —— 该语言/脚本没有可用模型")
        return
    }
    log("[\(label)] id=\(e.modelIdentifier) dim=\(e.dimension) maxSeqLen=\(e.maximumSequenceLength) hasAvailableAssets=\(e.hasAvailableAssets)")

    let t0 = Date()
    do {
        try e.load()
        log("[\(label)] load() OK in \(f(Date().timeIntervalSince(t0), 3))s")
    } catch {
        log("[\(label)] load() FAILED in \(f(Date().timeIntervalSince(t0), 3))s: \(error)")
        guard !assetRequestAttempted else {
            log("[\(label)] 跳过 requestAssets（前面已经试过一次，行为一致，省时间）")
            return
        }
        assetRequestAttempted = true
        log("[\(label)] -> 触发 requestAssets 看资源能不能下载")
        let sema = DispatchSemaphore(value: 0)
        let box = ResultBox()
        // 注意 Swift 名不是 requestEmbeddingAssets：omit-needless-words 把 "Embedding" 去掉了
        e.requestAssets { result, err in
            box.set("result=\(result.rawValue)(\(describe(result))) error=\(err.map { "\($0)" } ?? "nil")")
            sema.signal()
        }
        if sema.wait(timeout: .now() + 45) == .timedOut {
            log("[\(label)] requestAssets TIMED OUT after 45s —— completion handler 一次都没被调用")
            return
        }
        log("[\(label)] requestAssets -> \(box.get())")
        let t1 = Date()
        do {
            try e.load()
            log("[\(label)] load() after request OK in \(f(Date().timeIntervalSince(t1), 3))s")
        } catch {
            log("[\(label)] load() after request STILL FAILED: \(error)")
            return
        }
    }

    // 首次推理（冷）
    let t2 = Date()
    do {
        let r = try e.embeddingResult(for: pairs[0].1, language: language)
        log("[\(label)] first embeddingResult OK in \(f(Date().timeIntervalSince(t2), 4))s seqLen=\(r.sequenceLength) lang=\(r.language.rawValue)")
        let v = meanPooled(r)
        log("[\(label)] meanPooled dim=\(v.count) head=\(v.prefix(6).map { f($0, 4) })")
    } catch {
        log("[\(label)] first embeddingResult FAILED: \(error)")
        return
    }

    // 稳定态计时
    var warm: [Double] = []
    for _ in 0..<10 {
        let t = Date()
        _ = try? e.embeddingResult(for: pairs[0].1, language: language)
        warm.append(Date().timeIntervalSince(t))
    }
    log("[\(label)] warm embeddingResult avg over 10 = \(f(warm.reduce(0,+) / Double(warm.count) * 1000, 3))ms")

    log("[\(label)] pair similarities (mean-pooled token vectors):")
    for (kind, a, b) in pairs {
        guard let ra = try? e.embeddingResult(for: a, language: language),
              let rb = try? e.embeddingResult(for: b, language: language) else {
            log("  [\(kind)] embeddingResult failed")
            continue
        }
        let cos = cosine(meanPooled(ra), meanPooled(rb))
        log("  [\(kind)] cos=\(f(cos)) (seqLen \(ra.sequenceLength)/\(rb.sequenceLength))  「\(a)」 vs 「\(b)」")
    }

    e.unload()
    log("[\(label)] unload() done")
}

func describe(_ r: NLContextualEmbedding.AssetsResult) -> String {
    switch r {
    case .available: return "available"
    case .notAvailable: return "notAvailable"
    case .error: return "error"
    @unknown default: return "unknown"
    }
}

final class ResultBox: @unchecked Sendable {
    private var value = "<none>"
    private let lock = NSLock()
    func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

probeContextual("zh-Hans/lang", NLContextualEmbedding(language: .simplifiedChinese), language: .simplifiedChinese, pairs: zhPairs)
probeContextual("Hans/script", NLContextualEmbedding(script: .simplifiedChinese), language: .simplifiedChinese, pairs: zhPairs)
probeContextual("en/lang", NLContextualEmbedding(language: .english), language: .english, pairs: enPairs)

// MARK: - [4] 语义检索小实验：句向量能不能把「问句」召回到「正确的文档」

log("")
log("================ [4] retrieval with NLEmbedding.sentenceEmbedding ================")

let zhCorpus = [
    "如何重置账户密码",          // 0
    "订单多久能发货",            // 1
    "支持哪些支付方式",          // 2
    "怎么申请退款",              // 3
    "客服的工作时间是几点到几点",  // 4
    "红烧肉的做法",              // 5
    "北京明天会下雨吗",          // 6
    "iPhone 的电池怎么保养",      // 7
]

let zhQueries: [(String, Int)] = [
    ("我忘记登录密码了", 0),
    ("我想把钱退回来", 3),
    ("包裹什么时候寄出去", 1),
    ("明天北京的天气如何", 6),
    ("可以用微信付钱吗", 2),
]

let enCorpus = [
    "How do I reset my account password",
    "How long until my order ships",
    "Which payment methods are supported",
    "How do I request a refund",
    "What are the customer support hours",
    "How to braise pork belly",
    "Will it rain in Beijing tomorrow",
    "How to take care of the iPhone battery",
]

let enQueries: [(String, Int)] = [
    ("I forgot my login password", 0),
    ("I want my money back", 3),
    ("When will my package be shipped", 1),
    ("What is the weather in Beijing tomorrow", 6),
    ("Can I pay with a credit card", 2),
]

func retrieval(_ label: String, _ lang: NLLanguage, corpus: [String], queries: [(String, Int)]) {
    guard let s = NLEmbedding.sentenceEmbedding(for: lang) else {
        log("[\(label)] sentenceEmbedding = nil，跳过")
        return
    }
    var hit = 0
    for (q, expected) in queries {
        let ranked = corpus.indices
            .map { (i: $0, sim: 1.0 - s.distance(between: q, and: corpus[$0], distanceType: .cosine)) }
            .sorted { $0.sim > $1.sim }
        let top = ranked[0]
        if top.i == expected { hit += 1 }
        let mark = top.i == expected ? "HIT " : "MISS"
        log("  [\(label)] \(mark) q=「\(q)」")
        log("        top1=「\(corpus[top.i])」 sim=\(f(top.sim))  expected=「\(corpus[expected])」 sim=\(f(ranked.first { $0.i == expected }!.sim))")
        log("        ranking=\(ranked.prefix(4).map { "\(corpus[$0.i])(\(f($0.sim, 3)))" }.joined(separator: " > "))")
    }
    log("[\(label)] top-1 accuracy = \(hit)/\(queries.count)")

    // sanity：同一句话的距离应该是 0
    let self0 = s.distance(between: corpus[0], and: corpus[0], distanceType: .cosine)
    log("[\(label)] sanity distance(self, self) = \(f(self0, 6))")
    log("[\(label)] vocabularySize = \(s.vocabularySize)  -> neighbors(for:) 有没有意义？\(s.vocabularySize == 0 ? "没有，词表是空的" : "有")")
    log("[\(label)] neighbors(for: 「\(corpus[0])」, max 3) = \(s.neighbors(for: corpus[0], maximumCount: 3, distanceType: .cosine).map { $0.0 })")
    log("[\(label)] contains(「\(corpus[0])」) = \(s.contains(corpus[0]))")
}

retrieval("zh-Hans", .simplifiedChinese, corpus: zhCorpus, queries: zhQueries)
log("")
retrieval("en", .english, corpus: enCorpus, queries: enQueries)

log("")
log("================ done ================")
exit(0)
