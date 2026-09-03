// spike: text-embedding-01 —— 只做类型检查，不需要模拟器。
// 目的：把 iOS 26.2 SDK 里 embedding 相关 API 的**精确 Swift 签名**固化下来，
// 免得下次又照着官网（已是 iOS 27）或 ObjC 头文件的名字瞎猜。
//
// 关键发现：ObjC 的 `requestEmbeddingAssetsWithCompletionHandler:` 在 Swift 里叫
// `requestAssets(completionHandler:)` —— omit-needless-words 把 "Embedding" 吃掉了。

import Foundation
import NaturalLanguage

// MARK: - NLEmbedding：词向量 + 句向量都在同一个类上

func nlEmbeddingShapes() throws {
    // 词向量（iOS 13.0+）
    let _: NLEmbedding? = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
    let _: NLEmbedding? = NLEmbedding.wordEmbedding(for: .simplifiedChinese, revision: 1)

    // 句向量（iOS 14.0+）—— 存在！backlog 里「NLEmbedding 只是词向量」的说法不成立
    let sent: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
    let _: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese, revision: 1)

    // 自定义词典 → 自建 embedding（只支持「字符串 → 定长向量」的查表，不能做推理）
    let _: NLEmbedding? = try? NLEmbedding(contentsOf: URL(fileURLWithPath: "/dev/null"))
    try NLEmbedding.write(["a": [0.0, 1.0]], language: .english, revision: 1,
                          to: URL(fileURLWithPath: "/tmp/x.mlmodel"))

    guard let e = sent else { return }

    let _: Int = e.dimension
    let _: Int = e.vocabularySize
    let _: NLLanguage? = e.language
    let _: Int = e.revision
    let _: Bool = e.contains("今天")

    // NLDistance = Double；.cosine 语义是 1 - cosine similarity，值域 [0, 2]
    let _: NLDistance = e.distance(between: "甲", and: "乙", distanceType: .cosine)
    let _: [Double]? = e.vector(for: "今天天气真好")
    let _: [(String, NLDistance)] = e.neighbors(for: "今天", maximumCount: 5, distanceType: .cosine)
    let _: [(String, NLDistance)] = e.neighbors(for: [0.0, 1.0], maximumCount: 5, distanceType: .cosine)
    e.enumerateNeighbors(for: "今天", maximumCount: 5, distanceType: .cosine) { _, _ in true }

    // 版本查询：词向量与句向量是两套独立的 revision
    let _: IndexSet = NLEmbedding.supportedRevisions(for: .simplifiedChinese)
    let _: Int = NLEmbedding.currentRevision(for: .simplifiedChinese)
    let _: IndexSet = NLEmbedding.supportedSentenceEmbeddingRevisions(for: .simplifiedChinese)
    let _: Int = NLEmbedding.currentSentenceEmbeddingRevision(for: .simplifiedChinese)
}

// MARK: - NLContextualEmbedding（iOS 17.0+）

func nlContextualEmbeddingShapes() async throws {
    // 目录查询：三个 key —— .languages / .scripts / .revision
    let _: [NLContextualEmbedding] = NLContextualEmbedding.contextualEmbeddings(forValues: [:])
    let _: [NLContextualEmbedding] = NLContextualEmbedding.contextualEmbeddings(
        forValues: [.languages: [NLLanguage.simplifiedChinese.rawValue],
                    .scripts: [NLScript.simplifiedChinese.rawValue],
                    .revision: 1])

    // 三种构造方式（`init()` 是 NS_UNAVAILABLE）
    let _: NLContextualEmbedding? = NLContextualEmbedding(language: .simplifiedChinese)
    let _: NLContextualEmbedding? = NLContextualEmbedding(script: .simplifiedChinese)
    guard let e = NLContextualEmbedding(modelIdentifier: "some.model.id") else { return }

    let _: String = e.modelIdentifier
    let _: [NLLanguage] = e.languages
    let _: [NLScript] = e.scripts
    let _: Int = e.revision
    let _: Int = e.dimension
    let _: Int = e.maximumSequenceLength
    let _: Bool = e.hasAvailableAssets

    // 资源管理：注意 Swift 名是 requestAssets，不是 requestEmbeddingAssets
    e.requestAssets { (result: NLContextualEmbedding.AssetsResult, error: Error?) in
        switch result {
        case .available: break
        case .notAvailable: break
        case .error: break
        @unknown default: break
        }
        _ = error
    }
    let _: NLContextualEmbedding.AssetsResult = try await e.requestAssets()

    // 加载 / 卸载：load 是 throws（ObjC 的 loadWithError:）
    try e.load()
    defer { e.unload() }

    // 推理：language 传 nil 就让它自己猜
    let r: NLContextualEmbeddingResult = try e.embeddingResult(for: "今天天气真好", language: .simplifiedChinese)
    let _: String = r.string
    let _: NLLanguage = r.language
    let _: Int = r.sequenceLength

    // 只有 token 级向量，**没有**句子级向量 —— 要句向量得自己 pooling
    r.enumerateTokenVectors(in: r.string.startIndex..<r.string.endIndex) { (vec: [Double], range: Range<String.Index>) -> Bool in
        _ = (vec, range)
        return true
    }
    let _: ([Double], Range<String.Index>)? = r.tokenVector(at: r.string.startIndex)
}

// MARK: - 反面证据：NL 的其他类型没有任何 embedding 能力

func noEmbeddingElsewhere() {
    // NLTagger 只有 tag/tagHypotheses；NLModel 只有 predictedLabel*；
    // NLLanguageRecognizer 只有 languageHypotheses。全部是「离散标签」输出，拿不到向量。
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .sentimentScore])
    tagger.string = "今天天气真好"
    let _: (NLTag?, Range<String.Index>) = tagger.tag(at: "今天天气真好".startIndex,
                                                      unit: .word, scheme: .lexicalClass)
    let _: ([String: Double], Range<String.Index>) = tagger.tagHypotheses(at: "今天天气真好".startIndex,
                                                                          unit: .word, scheme: .lexicalClass,
                                                                          maximumCount: 3)
    let rec = NLLanguageRecognizer()
    rec.processString("今天天气真好")
    let _: [NLLanguage: Double] = rec.languageHypotheses(withMaximum: 3)
}
