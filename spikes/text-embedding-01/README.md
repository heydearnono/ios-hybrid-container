# spike: text-embedding-01

- **日期**：2026-09-03
- **环境**：macOS 15.7.3 / Xcode 26.2（17C52）/ Swift 6.2.3 / iOS 26.2 模拟器（iPhone 17 Pro、iPhone Air）
- **对应笔记**：[`docs/04-multimodal/text-embedding.md`](../../docs/04-multimodal/text-embedding.md)

## 要验证的问题

backlog 04 分组 P1：**iOS 上有没有可用的句向量 / 文本嵌入 API 做语义检索？**
（原问题描述说「`NLEmbedding` 只是词向量」—— 这个前提本身要先核实。）

拆成四问：

1. iOS 26.2 SDK 里到底有哪些 embedding API？精确签名是什么？`FoundationModels` 有没有暴露 embedding？
2. 这些 API 在 iOS 26.2 模拟器上**真的能用吗**？中文支持如何？维度多少？要不要下载资源？
3. 相似度数字长什么样：近义 / 无关 / 反义句对的余弦相似度。
4. 拿它做「问句 → FAQ 条目」的语义检索，top-1 命中率是多少？

## 怎么跑

```bash
./run.sh              # 类型检查 + 模拟器实跑（默认 iPhone 17 Pro）
./run.sh typecheck    # 只做类型检查，不需要模拟器
./run.sh app          # 额外打一个最小 .app 进模拟器跑
```

二进制编到 `mktemp` 目录，跑完自动删，仓库里不留产物。日志走 **stderr**
（`stdout` 过管道是块缓冲，进程被 kill 就什么都看不到，foundation-models-01 已经踩过）。

**在一台全新模拟器上第一次跑，结果会和第二次不一样** —— 见下面结论 3。想复现「冷状态」，
换一台从没跑过的模拟器（`DEVICE_NAME="iPhone Air" ./run.sh`）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `api-typecheck.swift` | 把 26.2 的精确签名钉住，`swiftc -typecheck` 过（含反面证据：`NLTagger` / `NLModel` / `NLLanguageRecognizer` 都拿不到向量） |
| `embedding-probe.swift` | 主探针：可用性扫描 → 句对相似度 → `NLContextualEmbedding` 目录与加载 → 检索小实验 |
| `contextual-in-app-probe.swift` | 对照探针：同样的 `NLContextualEmbedding.load()`，但跑在真 `.app` 容器里 |
| `run.sh` | 唯一入口 |

## 结论

1. **`NLEmbedding.sentenceEmbedding(for:)` 存在**（iOS 14+），backlog 里「只是词向量」的前提不成立。
   zh-Hans 维度 **640**、en 维度 **512**。`vocabularySize == 0`（无固定词表），
   所以 `neighbors(for:)` 返回空数组 —— 只能算两两距离，不能做近邻搜索。

2. **中文句向量的语义质量不够做语义检索**。8 条 FAQ + 5 个改写问句，
   中文 top-1 命中 **1/5**，英文 **3/5**。中文的失败模式很一致：
   最长的那条文档（「客服的工作时间是几点到几点」）在 5 个 query 里赢了 3 次。
   句对相似度里，**反义句 0.9027 比近义句 0.7072/0.7293 还高**，无关句 0.6648 紧贴近义句。

3. **句向量资源是按需下载的 MobileAsset，全新设备上 `sentenceEmbedding(for:)` 返回 `nil`**。
   在一台从未跑过的模拟器（iPhone Air）上：zh-Hans 词向量和句向量都是 `nil`，
   en 词向量有（运行时内置）但句向量 `nil`。跑过一次 `NLContextualEmbedding.requestAssets`
   之后，`com_apple_MobileAsset_LinguisticData` 下出现 4 个 asset，**下一次进程启动**句向量就有了。
   `NLEmbedding` 自己**没有**任何请求资源的 API。

4. **`NLContextualEmbedding` 在 iOS 26.2 模拟器上完全用不了**。目录能读（6 个模型、全部 dim=512 /
   maxSeqLen=256），但 `load()` 永远失败：
   - 资源未下载：`NLNaturalLanguageErrorDomain Code=8 "Failed to locate embedding model"`
   - 资源已下载：`Code=7 "Embedding model requires compilation"`，卡死不动
   打成真 `.app`（有 App 容器、caches 可写）结果**一模一样**，所以不是权限/容器问题。
   资源里是 `mBERT.bundle`，含 `embeddings.mil` + `*.espresso.net` —— 需要 Core ML 编译，
   模拟器上这一步没人做。

5. **`requestAssets` 的 completion handler 在冷设备上一次都不回调**（等 45s 超时）。
   官方文档说它「在框架已知资源状态或出错时立即返回」，实测不符。资源确实被拉下来了，
   但只能靠下一次启动才看得到。

6. **`FoundationModels` 26.2 完全没有 embedding API**（`.swiftinterface` 里 `embed` 零命中）。
   `NLTagger` / `NLModel` / `NLLanguageRecognizer` 也都只给离散标签，拿不到向量。

完整数值和相似度表见笔记的「实测数据」一节。
