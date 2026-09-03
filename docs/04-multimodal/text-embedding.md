# iOS 文本嵌入与语义检索

- **更新时间**：2026-09-03
- **适用版本**：**iOS 26.2 SDK**（`NaturalLanguage` Swift overlay user-version 4.3）/ Xcode 26.2（17C52）/ Swift 6.2.3。
  `NLEmbedding` 自 iOS 13.0 起提供，句向量部分自 **iOS 14.0**；`NLContextualEmbedding` 自 **iOS 17.0**。
  ⚠️ 官网文档当前已切到 iOS 27，本文所有签名都对着本机 26.2 SDK 头文件与 `.swiftinterface` 核对过。
- **验证方式**：本机 SDK 头文件 + Swift overlay `.swiftinterface` 实证 + **iOS 26.2 模拟器实跑**
  （iPhone 17 Pro 与 iPhone Air 两台，后者用于复现「全新设备」冷状态）
- **相关 spike**：[`spikes/text-embedding-01/`](../../spikes/text-embedding-01/)

## 一句话结论

**API 有，能力不够。** 首先纠正一个前提：`NLEmbedding` **不只是词向量**，
`sentenceEmbedding(for:)` 从 iOS 14 就存在，中文（zh-Hans）在 iOS 26.2 上给的是 **640 维句向量**。
但实测它的中文语义质量做不了语义检索：8 条 FAQ + 5 个改写问句，**中文 top-1 命中 1/5**（英文 3/5），
而且**反义句相似度 0.9027 高于近义句 0.7072** —— 它更像在量「句子表面像不像」，不是「意思像不像」。

`NLContextualEmbedding`（mBERT，512 维）**在 iOS 26.2 模拟器上根本加载不起来**
（`load()` 恒抛 `Code=7 "Embedding model requires compilation"`），而且 Apple 自己在文档里写着
「做语义相似度请用 `NLEmbedding`」，它的定位是 Create ML 的特征提取器。

**结论：中文语义检索走系统框架这条路不通。** 用云端 embedding API 做主线，
需要端侧兜底时自带一个 Core ML 句向量模型（如 sentence-transformers 系列转 Core ML）。
本项目短期不做端侧语义检索。

## 能做什么

| 能力 | 关键 API | 本机 26.2 实测 |
| --- | --- | --- |
| 词向量（静态查表） | `NLEmbedding.wordEmbedding(for:)` | zh-Hans / en 可用，均 300 维；vocab 30278 / 57171 |
| 句向量（任意句子） | `NLEmbedding.sentenceEmbedding(for:)` | zh-Hans **640 维**、en **512 维**；`vocabularySize == 0` |
| 两两余弦距离 | `distance(between:and:distanceType: .cosine)` | 可用，同句距离精确为 0 |
| 取原始向量 | `vector(for:)` → `[Double]?` | 可用；空串返回 `nil`，乱码/emoji 返回非零向量 |
| 词向量近邻搜索 | `neighbors(for:maximumCount:distanceType:)` | **只对词向量有效**，句向量返回 `[]` |
| 自建 embedding | `NLEmbedding(contentsOf:)` / `NLEmbedding.write(_:language:revision:to:)` / Create ML `MLWordEmbedding` | 仅编译期类型验证，未实跑 |
| 上下文向量（token 级） | `NLContextualEmbedding` + `embeddingResult(for:language:)` | **目录可读，`load()` 恒失败**，见下 |
| 目录查询 | `NLContextualEmbedding.contextualEmbeddings(forValues:)` | 可用；6 个模型，全部 dim=512 / maxSeqLen=256 |

## 不能做什么 / 边界

这一节比上一节重要得多。

### 1. 中文句向量的语义判别力不足 —— 这是最硬的一条

Apple 官方文档给的正是「FAQ 检索」这个场景：用户搜 "Where is my order?"，
用句向量匹配到 FAQ 标题 "How do I check the status of my order?"
（[Finding similarities between pieces of text](https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text)）。
spike 把这个场景原样搭了一遍（8 条中文 FAQ + 5 个改写问句），结果：

- **中文 top-1 命中 1/5**，英文 3/5。
- 中文的失败模式非常一致：**最长的那条文档赢**。「客服的工作时间是几点到几点」在 5 个 query 里
  被排到第一 3 次，包括「包裹什么时候寄出去」和「明天北京的天气如何」。
- 句对相似度直接暴露问题（cos = 1 − `NLDistance`）：

  | 关系 | 中文 cos | 英文 cos |
  | --- | --- | --- |
  | 近义 | 0.7072 / 0.7293 | 0.2294 |
  | 无关 | 0.6648 / 0.5440 | −0.2819 |
  | **反义** | **0.9027** | 0.3335 |

  中文的「无关」（0.6648）几乎贴着「近义」（0.7072），而「反义」冲到 0.9027 —— **没有可用的判别阈值**。
  英文至少「无关」是负数，近义/无关分得开，但「反义 > 近义」这个毛病两种语言都有
  （反义句只差一个字，表面高度重合）。

**这不是调参能救的问题**：0.66 vs 0.71 的间隔里塞不进任何阈值。

### 2. 句向量没有词表，近邻搜索用不了

`sentenceEmbedding` 的 `vocabularySize == 0`，`neighbors(for:maximumCount:)` 实测返回 `[]`。
官方也明说：「Sentence embeddings are dynamic. They don't have a fixed vocabulary...
Nearest-neighbor search therefore doesn't apply to sentence embeddings.」
（[同上](https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text)）

**含义**：做检索必须自己维护向量库、自己算 top-k。框架只给你「两个字符串之间的距离」。
语料一大，`distance(between:and:)` 的 O(N) 调用会成为瓶颈，得自己缓存 `vector(for:)` 的结果。

### 3. `NLEmbedding` 不是并发安全的 —— 会崩，不是变慢

官方在 `NLEmbedding` 和 `vector(for:)` 两处都用 Important 标注：

> A single `NLEmbedding` instance isn't safe for concurrent use. Although its query methods, like
> `vector(for:)`, look like read-only lookups, calling them on one instance from multiple threads
> or tasks at the same time can crash your app.
> （[NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)、
> [vector(for:)](https://developer.apple.com/documentation/naturallanguage/nlembedding/vector(for:))）

**含义**：想并行给一批文档算向量，要么串行化（actor / 串行队列），要么每个线程各持一个实例。
批量索引正是最想并行的场景，这条直接抹掉了并行加速的可能。⚠️ 未验证：实际崩溃我没有复现，
这里只引官方警告。

### 4. 句向量资源是按需下载的，全新设备上 `sentenceEmbedding(for:)` 返回 `nil`

这是最容易在测试机上蒙混过去、到用户设备上翻车的一条。在一台从没跑过任何东西的
iPhone Air 模拟器上首次运行：

```
zh-Hans: word=nil            sentence=nil     (wordRevs=[1] sentRevs=[1])
en:      word=dim=300 ...    sentence=nil     (wordRevs=[1] sentRevs=[1])
```

注意 `supportedSentenceEmbeddingRevisions(for:)` 返回 `[1]`（"支持"），
但 `sentenceEmbedding(for:)` 返回 `nil`（"现在拿不到"）。**这两个 API 回答的不是同一个问题**，
不能用前者做可用性判定。

原因是资源在 `com.apple.MobileAsset.LinguisticData` 里，`LinguisticAssetType = Optional`，按需下载。
本机路径证据（`.../CoreSimulator/Devices/<UDID>/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData/`）：
`Language = zh_Hans` 的 asset 里有 `embedding.dat`（3.9MB，词向量）和 `bilm.dat`（15MB，句向量的
双向语言模型）。en 的词向量 `embedding.dat` 内置在运行时
（`RuntimeRoot/System/Library/LinguisticData/RequiredAssets_en.bundle/AssetData/embedding.dat`），
所以冷设备上 en 词向量能用、句向量不能。

**致命的地方**：`NLEmbedding` **没有任何请求资源的 API**。没有 `hasAvailableAssets`，
没有 `requestAssets`，只有一个返回 `nil` 的工厂方法。你既不知道它什么时候会好，也没法催。
⚠️ 未验证：spike 里资源是在调用了 `NLContextualEmbedding.requestAssets` 之后出现的，
但无法确定是这个调用触发的下载，还是系统自己在后台拉的 —— 两者时间上重合。

**含义**：任何用 `sentenceEmbedding` 的功能都必须能在返回 `nil` 时正常降级，
且这个 `nil` 可能持续到用户联网并等系统下载完为止。

### 5. `NLContextualEmbedding` 在 iOS 26.2 模拟器上完全不可用

目录读得到，模型加载不了。实测 `load()` 的两个失败态：

| 前置状态 | `load()` 报错 |
| --- | --- |
| `hasAvailableAssets == false` | `NLNaturalLanguageErrorDomain Code=8 "Failed to locate embedding model"` |
| `hasAvailableAssets == true` | `NLNaturalLanguageErrorDomain Code=7 "Embedding model requires compilation"` |

Code=7 是**永久卡死**：重复 `load()`、间隔 20s 重试 3 次、跨进程重启、等待 1 分钟以上，全部同样报错。
再调 `requestAssets` 会拿到 `AssetsResult.error` +
`Code=7 "Aborting repeated compilation request"`。

**排除了「裸进程没有 App 容器」这个解释**：spike 里额外打了一个最小 `.app`
（`contextual-in-app-probe.swift` + `run.sh app`）装进模拟器跑，`NSHomeDirectory` 是正常的
App 容器、caches 可写，`load()` 报错**一模一样**。

根因看资源内容就清楚了：模型是 `mBERT.bundle`，里面是 `embeddings.mil`（Core ML MIL 中间表示）
加 `cpu_embeddings.espresso.net` / `unilm_joint.espresso.weights`。**需要一次设备端 Core ML 编译**，
而模拟器上这一步没有发生。

⚠️ **未验证**：真机上这次编译能不能成功。这和 Foundation Models 的阻塞不是同一件事
（`NLContextualEmbedding` 不需要 Apple Intelligence），但同样**只能等真机才能定论**。
未在 macOS 宿主上做对照实验 —— 那需要往宿主系统下载 LinguisticData 资源，不做。

### 6. `NLContextualEmbedding` 只给 token 向量，而且 Apple 让你别拿它做相似度

- `NLContextualEmbeddingResult` 只有 `enumerateTokenVectors(in:using:)` 和
  `tokenVector(at:)`，**没有句子级向量**。要句向量得自己 mean-pooling。
- Apple 在类文档里直接写了：

  > For semantic similarity tasks, consider using `NLEmbedding`.
  > （[NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)）

  它的定位是「Create ML 里选 `bertEmbedding` 作为特征提取器」去训文本分类 / 词标注模型。
- `maximumSequenceLength = 256`（实测 6 个模型全是 256）。中文按字切分的话，
  **256 token 大约就是 256 个汉字**的上限。⚠️ 未验证：具体分词粒度没测到（`load()` 就没成功）。

### 7. `requestAssets` 的回调行为与文档不符

官方说：

> This method returns immediately if the framework knows the state of the assets or if an error occurs.
> （[requestAssets(completionHandler:)](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/requestassets(completionhandler:))）

实测在冷设备（`hasAvailableAssets == false`）上，**completion handler 45 秒内一次都没被调用**。
资源确实被下载了（下一次进程启动 `hasAvailableAssets` 变 `true`），但这一次调用永远不返回。

**含义**：和 Foundation Models 的 `respond()` 挂死是同一类坑 —— **必须自己加超时兜底**，
不能 `await requestAssets()` 然后指望它一定返回。

### 8. 语言覆盖：句向量的语言列表 Apple 没有公开

- **`NLContextualEmbedding` 的语言列表有官方文档**：iOS 17 起 27 种语言 / 3 个模型（Latin、Cyrillic、CJK），
  iOS 18 增加 Arabic、Indic、Thai 三个模型
  （[languages](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/languages)）。
  本机实测到的 6 个模型与之完全对应，见「实测数据」。
- **`NLEmbedding` 的句向量支持哪些语言，官方文档里没有列表**。`sentenceEmbedding(for:)` 的文档只有一句
  "An `NLEmbedding` if available, otherwise `nil`"
  （[sentenceEmbedding(for:)](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:))）。
  ⚠️ 未验证：只能靠实测穷举。本机实测 zh-Hans 和 en 有；zh-Hant / ja / ko / ru / ar 连
  `supportedSentenceEmbeddingRevisions` 都是空；fr / de / es / it / pt 的 revision 是 `[1]`
  但实例仍为 `nil`（资源未下载，见边界 4，无法区分「没有模型」和「没下载」）。

### 9. `FoundationModels` 26.2 没有 embedding 能力

本机 `FoundationModels.swiftinterface` 里 `grep -i embed` **零命中**
（`iPhoneSimulator26.2.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/*.swiftinterface`，module user-version 1.1.7）。
`NLTagger` / `NLModel` / `NLLanguageRecognizer` 也都只输出离散标签
（`tag` / `tagHypotheses` / `predictedLabelHypotheses` / `languageHypotheses`），拿不到向量。
全 SDK 扫过一遍 `System/Library/Frameworks` 下的头文件与 `.swiftinterface`，
除 `NaturalLanguage` 之外没有第二个公开的文本嵌入 API。

## 关键 API

签名逐条抄自本机头文件，完整可编译文件见
[`spikes/text-embedding-01/api-typecheck.swift`](../../spikes/text-embedding-01/api-typecheck.swift)（`-typecheck` 退出码 0）。

### `NLEmbedding` 句向量

源文件：`$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/NaturalLanguage.framework/Headers/NLEmbedding.h`
第 25–26 行（ObjC）、Swift overlay
`iPhoneSimulator26.2.sdk/usr/lib/swift/NaturalLanguage.swiftmodule/arm64-apple-ios-simulator.swiftinterface`
第 50–63 行。

```swift
import NaturalLanguage

// 句向量：iOS 14.0+，可能返回 nil（资源未下载 / 该语言没有模型）
guard let embedding = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) else {
    return   // 必须有降级路径，见「边界 4」
}

// NLDistance = Double；.cosine 语义是 1 - cosine similarity，值域 [0.0, 2.0]
let distance: NLDistance = embedding.distance(between: "我忘记密码了",
                                              and: "如何重置账户密码",
                                              distanceType: .cosine)
let similarity = 1.0 - distance

// 原始向量：空串返回 nil
let vector: [Double]? = embedding.vector(for: "我忘记密码了")

// 元数据
_ = embedding.dimension        // zh-Hans: 640, en: 512
_ = embedding.vocabularySize   // 句向量恒为 0
_ = embedding.language         // Optional<NLLanguage>
```

**不要用 `vector(for:)` 手算余弦去替代 `distance(between:and:)`** ——
实测两者数值差很多（中文近义句：`distance` 给 0.7072，手算给 0.9571）。
原始向量里有很大的共同分量，中文任意两句的手算余弦都在 0.89–0.99 之间，完全没有区分度。
`distance(between:and:)` 显然做了额外的归一化/中心化，**它才是应该用的那个**。
⚠️ 未验证：具体做了什么变换，Apple 没有文档，只能观察到数值不一致。

版本查询 API 回答的是「SDK 支不支持」，**不是**「现在能不能用」：

```swift
NLEmbedding.supportedSentenceEmbeddingRevisions(for: .simplifiedChinese)  // IndexSet, [1]
NLEmbedding.currentSentenceEmbeddingRevision(for: .simplifiedChinese)     // Int, 1
// 上面两个在句向量返回 nil 时**照样**给这些值
```

### `NLContextualEmbedding`

源文件：`.../NaturalLanguage.framework/Headers/NLContextualEmbedding.h`（103 行全文）。
**Swift 名和 ObjC 名对不上，这里最容易踩**：

| ObjC | Swift（26.2 实测） |
| --- | --- |
| `+contextualEmbeddingWithLanguage:` | `NLContextualEmbedding(language:)` |
| `+contextualEmbeddingWithScript:` | `NLContextualEmbedding(script:)` |
| `+contextualEmbeddingWithModelIdentifier:` | `NLContextualEmbedding(modelIdentifier:)` |
| `+contextualEmbeddingsForValues:` | `NLContextualEmbedding.contextualEmbeddings(forValues:)` |
| `-loadWithError:` | `func load() throws` |
| `-embeddingResultForString:language:error:` | `func embeddingResult(for:language:) throws -> NLContextualEmbeddingResult` |
| **`-requestEmbeddingAssetsWithCompletionHandler:`** | **`requestAssets(completionHandler:)`** / `requestAssets() async throws` |

最后一行是重点：omit-needless-words 把 `Embedding` 吃掉了，**Swift 里没有
`requestEmbeddingAssets` 这个名字**（照着头文件写会编译不过，且编译器不给改名提示）。

```swift
guard let e = NLContextualEmbedding(language: .simplifiedChinese) else { return }

_ = e.modelIdentifier          // 例：12784592-5D67-4F4C-83D6-A346519146AE
_ = e.dimension                // 512
_ = e.maximumSequenceLength    // 256
_ = e.hasAvailableAssets       // Bool

if !e.hasAvailableAssets {
    // 必须自己加超时：实测冷设备上这个回调可能永远不来（见「边界 7」）
    let result: NLContextualEmbedding.AssetsResult = try await e.requestAssets()
    // .available / .notAvailable / .error（非 @frozen，switch 留 @unknown default）
    _ = result
}

try e.load()                   // iOS 26.2 模拟器上恒抛错，见「边界 5」
defer { e.unload() }

let r = try e.embeddingResult(for: "今天天气真好", language: .simplifiedChinese)
_ = r.sequenceLength

// 只有 token 级向量，句向量要自己 mean-pooling
var sum = [Double](repeating: 0, count: e.dimension)
var n = 0
r.enumerateTokenVectors(in: r.string.startIndex..<r.string.endIndex) { vec, _ in
    for i in 0..<vec.count { sum[i] += vec[i] }
    n += 1
    return true
}
let pooled = sum.map { $0 / Double(n) }
```

目录查询有个坑：**传空字典查不出任何东西**（实测返回 0 个），必须至少给一个 key。
`.revision: 1` 也返回 0 —— 只有按 `.languages` / `.scripts` 查才有结果。

```swift
NLContextualEmbedding.contextualEmbeddings(forValues: [:])            // 实测 0 个
NLContextualEmbedding.contextualEmbeddings(forValues: [.revision: 1]) // 实测 0 个
NLContextualEmbedding.contextualEmbeddings(
    forValues: [.scripts: [NLScript.simplifiedChinese.rawValue]])     // 实测 1 个
```

## 实测数据

环境：macOS 15.7.3 / Xcode 26.2（17C52）/ Swift 6.2.3 / **iOS 26.2 模拟器**
（iPhone 17 Pro 为主，iPhone Air 用于复现全新设备冷状态）。
spike：[`spikes/text-embedding-01/`](../../spikes/text-embedding-01/)

### API 与可用性

| 指标 | 环境 | 数值 | 备注 |
| --- | --- | --- | --- |
| `api-typecheck.swift` | iOS 26.2 SDK / Swift 6 | **通过**（exit 0，1 条 warning） | warning 是「建议用 async 版 `requestAssets`」 |
| `sentenceEmbedding(zh-Hans)` | 资源已下载 | dim=**640** vocab=0 rev=1 | |
| `sentenceEmbedding(en)` | 资源已下载 | dim=**512** vocab=0 rev=1 | |
| `wordEmbedding(zh-Hans)` | 资源已下载 | dim=300 vocab=**30278** | |
| `wordEmbedding(en)` | 冷设备也可用 | dim=300 vocab=**57171** | 内置在模拟器运行时里 |
| 其他 10 种语言 | 同上 | 词向量与句向量**全部 nil** | zh-Hant/ja/ko/ru/ar 连 revision 都是空 |
| `sentenceEmbedding` @ 全新设备 | iPhone Air 首次运行 | **nil**（zh-Hans 和 en 都是） | 资源未下载 |
| `sentenceEmbedding` @ 第二次运行 | 同一台 | 640 / 512 维，正常 | 资源已落到 MobileAsset |
| `NLContextualEmbedding` 模型数 | 按 script 穷举 | **6 个**，全部 dim=512 / maxSeqLen=256 | 与官方 27+ 语言的 6 模型说法一致 |
| `NLContextualEmbedding.load()` | 冷设备 | `Code=8 Failed to locate embedding model` | |
| `NLContextualEmbedding.load()` | 资源已下载 | **`Code=7 Embedding model requires compilation`** | 重试 / 重启 / 真 .app 容器都一样 |
| `requestAssets` 回调 | 冷设备 | **45s 内一次都没回调** | 资源实际被下载了 |
| `requestAssets` 回调 | 资源已下载但需编译 | `.error` + `Code=7 Aborting repeated compilation request` | |
| `FoundationModels` embedding API | 26.2 SDK | **不存在**（`grep -i embed` 零命中） | |

`NLContextualEmbedding` 的 6 个模型（`modelIdentifier` / 脚本 / 语言 / `hasAvailableAssets`）：

| modelIdentifier | scripts | languages | 资源已下载 |
| --- | --- | --- | --- |
| `5C45D94E-BAB4-4927-94B6-8B5745C46289` | Latn | cs da de en es fi fr hr hu id it nb nl pl pt ro sk sv tr vi（20） | 是 |
| `12784592-5D67-4F4C-83D6-A346519146AE` | Hans Hant Jpan Kore | ja ko zh-Hans zh-Hant（4） | 是 |
| `FCDCF262-68F6-4446-8C4E-371491BC04A2` | Cyrl | bg kk ru uk（4） | 否 |
| `8D8CD1B6-1D0E-4ADF-8D75-B5FD5F125186` | Arab | ar ars（2） | 否 |
| `FC4A7469-2001-45D6-9AD7-A7110800DBCA` | Beng Deva Gujr Guru Knda Mlym Taml Telu | bn gu hi kn ml mr pa-Guru ta te ur（10） | 否 |
| `54877656-5B75-40D8-95C8-75759FCBEF2F` | Thai | th（1） | 否 |

### 性能

| 指标 | 环境 | 数值 | 备注 |
| --- | --- | --- | --- |
| `sentenceEmbedding(for:)` 首次构造 | zh-Hans，资源已下载 | 0.001–0.010s | |
| 首次 `vector(for:)`（冷） | zh-Hans | **0.108s** | 另一轮 0.225s |
| 稳定态 `vector(for:)` | zh-Hans，10 次均值 | **5.04ms** | 另一轮 27.1ms，抖动大 |
| 稳定态 `vector(for:)` | en，10 次均值 | **5.75ms** | 另一轮 9.04ms |
| `NLContextualEmbedding` 推理耗时 | — | **未实测** | `load()` 从未成功 |
| 真机耗时 | — | **未实测** | 无真机；模拟器数字仅供数量级参考 |
| 峰值内存 | — | **未实测** | |

### 语义质量（这是决定性的一节）

句对余弦相似度，`cos = 1 - distance(between:and:distanceType: .cosine)`：

| 关系 | 句 A | 句 B | cos |
| --- | --- | --- | --- |
| 近义 | 今天天气真好 | 今天的天气很不错 | 0.7072 |
| 近义 | 怎么重置我的登录密码 | 我忘记密码了要怎么办 | 0.7293 |
| 无关 | 今天天气真好 | 这台电脑的内存是十六个吉字节 | 0.6648 |
| 无关 | 怎么重置我的登录密码 | 红烧肉需要先炒糖色 | 0.5440 |
| **反义** | 这家餐厅的菜非常好吃 | 这家餐厅的菜非常难吃 | **0.9027** |
| 同词不同义 | 他把桌上的苹果吃掉了 | 苹果公司发布了新手机 | 0.6503 |
| 近义（en） | The weather is really nice today | Today's weather is quite good | 0.2294 |
| 无关（en） | The weather is really nice today | This laptop has sixteen gigabytes of memory | −0.2819 |
| **反义（en）** | The food at this restaurant is delicious | The food at this restaurant is terrible | **0.3335** |

检索实验：8 条 FAQ 文档，5 个改写问句，按 `distance` 排 top-1。

| 语言 | top-1 命中 | 典型失败 |
| --- | --- | --- |
| **zh-Hans** | **1/5** | 「包裹什么时候寄出去」→ 命中「客服的工作时间是几点到几点」(0.760)，正确答案「订单多久能发货」只有 0.6455 |
| **en** | **3/5** | 「Can I pay with a credit card」→ 命中「How do I request a refund」(0.138)，正确答案「Which payment methods are supported」是 −0.0077 |

中文 5 个 query 里，「客服的工作时间是几点到几点」（语料里最长的一条）被排到第一 **3 次**。

其他行为：

| 探测 | 结果 |
| --- | --- |
| `distance(self, self)` | 0.000000（sanity 通过） |
| `vector(for: "")` | `nil` |
| `vector(for: "asdkjhqwe zxcvbnm")` | 640/512 维非零向量（未登录输入不报错，给一个向量） |
| `vector(for: "🙂🙂🙂")` | 同上，非零 |
| 720 字中文长输入 | 正常返回 640 维（不报错、不截断提示） |
| `neighbors(for:)`（句向量） | `[]` |
| `contains(_:)`（句向量） | `true`（对任意字符串都 true，无参考价值） |

## 踩坑记录

- **句向量在全新设备上是 `nil`，而 `supportedSentenceEmbeddingRevisions` 照样返回 `[1]`**。
  现象：iPhone Air 首次跑，zh-Hans / en 句向量全 nil，但 revision 查询正常。
  原因：资源在 `com.apple.MobileAsset.LinguisticData` 的 `Optional` asset 里，按需下载。
  解决：可用性判定**只能靠 `sentenceEmbedding(for:) != nil`**，并且必须准备降级路径 ——
  `NLEmbedding` 没有请求资源的 API，也没有状态查询。
- **`vector(for:)` 手算余弦 ≠ `distance(between:and:)`**。现象：中文近义句手算 0.9571，
  `distance` 给 0.7072；中文任意两句手算余弦都在 0.89 以上，毫无区分度。
  原因：原始向量有很大共同分量，`distance` 显然做了额外归一化（Apple 未文档化）。
  解决：**永远用 `distance(between:and:distanceType:)`**，不要拿 `vector(for:)` 自己算。
- **Swift 里没有 `requestEmbeddingAssets`**。现象：照 ObjC 头文件写
  `e.requestEmbeddingAssets { ... }`，报 `has no member`，且编译器**不给** "did you mean" 提示。
  原因：omit-needless-words 把和类名重复的 `Embedding` 去掉了，实际名字是 `requestAssets`。
  解决：查 ObjC 框架的 Swift 名，用 `swiftc -typecheck` 试，不要照抄头文件。
- **`contextualEmbeddings(forValues: [:])` 返回空数组**。现象：想枚举全部模型，传空字典拿到 0 个。
  解决：按 `.scripts` 或 `.languages` 逐个查，自己去重（spike 里就是这么穷举出 6 个模型的）。
- **`NLContextualEmbedding` 卡在 "requires compilation" 上，不是权限问题**。
  排查过程：先怀疑 `simctl spawn` 的裸进程没有 App 容器写不了编译产物 →
  打了个最小 `.app` 装进模拟器跑，`NSHomeDirectory` 正常、caches 可写、报错一字不变。
  再看资源内容，是 `mBERT.bundle` 里的 `embeddings.mil` + `*.espresso.net`，需要设备端 Core ML 编译。
  结论：**模拟器上这条路封死，等真机**。
- **`stdout` 块缓冲吃日志**（沿用 foundation-models-01 的教训）：`simctl spawn` 的日志一律写
  `FileHandle.standardError`。
- **模拟器会自己 shutdown**。现象：`simctl boot` 成功、`bootstatus` 报 Booted，隔几分钟再
  `simctl spawn` 就 `device is not booted` / `Bad or unknown session`。
  解决：`run.sh` 里每次跑之前都重新 `boot` + `bootstatus`。

## 结论与下一步

**选型倾向：不用。中文语义检索不走 `NaturalLanguage`。**

理由，按权重排序：

1. **中文语义质量不达标**。top-1 1/5、反义句相似度高于近义句、长句系统性占优。
   这不是阈值调参问题，是表示能力问题。
2. **可用性不可控且无法管理**。句向量资源按需下载，`NLEmbedding` 连查询和请求资源的 API 都没有，
   `nil` 可能持续任意长时间。
3. **`NLContextualEmbedding` 现在验证不了**，模拟器上 `load()` 恒失败；且即便真机能跑，
   Apple 自己也说它不该用来做语义相似度。
4. 并发不安全，批量建索引没法并行。

**替代方案，按推荐顺序**：

1. **云端 embedding API**（推荐，和本项目「云端为主线」的架构不变量一致）。
   语义质量由服务端模型决定，可换可升级；代价是需要网络、有调用成本、文本要出端。
   接入点应该和 `Packages/AICore` 里的 provider 抽象同构 —— 加一个 `EmbeddingProvider` 协议，
   mock / 云端两个实现。
2. **自带 Core ML 句向量模型**（端侧隐私场景的唯一可行路径）。
   把 sentence-transformers 一类的多语言句向量模型用 `coremltools` 转 Core ML 打进包。
   代价：包体积（几十到几百 MB）、要自己做分词、要自己做 pooling 和向量库。
   这条属于 `docs/02-coreml-mlx/` 的范围。⚠️ 未验证：本项目还没试过。
3. **不用向量**。中文 FAQ / 短文本检索，先试关键词 + 同义词表 + BM25。
   spike 的中文 top-1 是 1/5，一个人工同义词表大概就能超过它。
4. **`NLEmbedding.wordEmbedding` 做词级扩展**（有限但可靠）。300 维、zh-Hans 词表 30278，
   `neighbors(for:)` 在词向量上是**能用**的，适合「搜索词扩展」这种小场景，不适合句子检索。

**待验证问题**（需要同步到 `docs/backlog.md`，本次未改索引文件）：

- **真机上 `NLContextualEmbedding.load()` 能否成功**？（模拟器 Core ML 编译不发生，只能等真机）
  这是本笔记唯一的悬空结论。
- 真机上 `sentenceEmbedding` 的中文质量是否与模拟器一致？（原则上是同一份 asset，应该一致，⚠️ 未验证）
- fr / de / es / it / pt 到底有没有句向量模型？（revision 是 `[1]` 但实例为 `nil`，
  区分不了「没模型」和「没下载」）
- 自带 Core ML 句向量模型的可行性与包体积代价（归 02 分组）。
- 云端 embedding provider 的抽象形状（归 03 分组）。

## 参考来源

- [NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding) — 类概述、**并发不安全的官方警告**
- [sentenceEmbedding(for:)](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:)) — 签名与「可能返回 nil」（文档里**没有**语言列表）
- [vector(for:)](https://developer.apple.com/documentation/naturallanguage/nlembedding/vector(for:)) — 并发警告的第二处
- [Finding similarities between pieces of text](https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text) — Apple 给的 FAQ 检索场景、「句向量没有词表所以近邻搜索不适用」
- [NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding) — **「语义相似度请用 NLEmbedding」**、定位为 Create ML 的 `bertEmbedding` 特征提取器
- [NLContextualEmbedding.languages](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/languages) — iOS 17 的 27 语言 / 3 模型，iOS 18 增加 Arabic / Indic / Thai
- [NLContextualEmbedding.load()](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/load()) — 资源缺失时失败
- [requestAssets(completionHandler:)](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/requestassets(completionhandler:)) — 「立即返回」的官方说法（实测不符）
- 本机头文件 `iPhoneOS26.2.sdk/System/Library/Frameworks/NaturalLanguage.framework/Headers/NLEmbedding.h` 第 13–17、25–26、51–55 行 — 句向量与 `NLDistance` 的权威签名
- 本机头文件 `.../Headers/NLContextualEmbedding.h`（全 103 行）— `load` / `embeddingResult` / `requestEmbeddingAssets` / `AssetsResult` 的 ObjC 原始声明
- 本机 Swift overlay `iPhoneSimulator26.2.sdk/usr/lib/swift/NaturalLanguage.swiftmodule/arm64-apple-ios-simulator.swiftinterface` 第 19–25、50–63 行（user-version 4.3）— `vector(for:)`、`distance(between:and:)`、`enumerateTokenVectors` 的 **Swift 精确签名**
- 本机 `iPhoneSimulator26.2.sdk/.../FoundationModels.swiftmodule/*.swiftinterface`（user-version 1.1.7）— `grep -i embed` 零命中，证明 Foundation Models 没有 embedding
- 本机模拟器资源 `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData/` — `LinguisticAssetType = Optional`、zh_Hans 的 `embedding.dat` / `bilm.dat`、`mBERT.bundle` 里的 `embeddings.mil`
- [`spikes/text-embedding-01/`](../../spikes/text-embedding-01/) — 本文所有实测数字的出处
