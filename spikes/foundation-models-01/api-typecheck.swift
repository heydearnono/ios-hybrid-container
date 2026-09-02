import FoundationModels
import Foundation

// 1) 可用性判定
func checkAvailability() -> String {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        return "available; zh supported=\(model.supportsLocale(Locale(identifier: "zh_CN")))"
    case .unavailable(.deviceNotEligible):
        return "deviceNotEligible"
    case .unavailable(.appleIntelligenceNotEnabled):
        return "appleIntelligenceNotEnabled"
    case .unavailable(.modelNotReady):
        return "modelNotReady"
    @unknown default:
        return "unknown"
    }
}

// 2) 结构化输出
@Generable
struct Recipe {
    @Guide(description: "菜名")
    var title: String
    @Guide(description: "步骤", .count(3...8))
    var steps: [String]
    @Guide(description: "分钟", .range(5...240))
    var minutes: Int
}

// 3) 工具调用
struct WeatherTool: Tool {
    let name = "getWeather"
    let description = "查询指定城市的当前天气"

    @Generable
    struct Arguments {
        @Guide(description: "城市名，如 Beijing")
        var city: String
    }

    func call(arguments: Arguments) async throws -> String {
        "\(arguments.city): 26°C, sunny"
    }
}

// 4) 基本对话 / 流式 / 结构化
func run() async throws {
    let session = LanguageModelSession(tools: [WeatherTool()]) {
        "你是一个简洁的中文助手。"
        "回答不超过两句话。"
    }
    session.prewarm()

    let reply = try await session.respond(to: "北京天气如何？",
                                          options: GenerationOptions(temperature: 0.3))
    _ = reply.content

    let stream = session.streamResponse(to: "写一首两行的诗",
                                        options: GenerationOptions(sampling: .greedy))
    for try await snapshot in stream {
        _ = snapshot.content  // String.PartiallyGenerated == String（累积快照）
    }
    _ = try await stream.collect().content

    let recipe = try await session.respond(to: "给我一个番茄炒蛋菜谱",
                                           generating: Recipe.self)
    _ = recipe.content.title

    let partialStream = session.streamResponse(to: "再来一个", generating: Recipe.self)
    for try await snap in partialStream {
        let partial: Recipe.PartiallyGenerated = snap.content
        _ = partial
    }

    _ = session.isResponding
    _ = session.transcript.count
}

// 5) 错误分类
func classify(_ error: Error) -> String {
    guard let e = error as? LanguageModelSession.GenerationError else { return "other" }
    switch e {
    case .exceededContextWindowSize: return "context-overflow"
    case .assetsUnavailable: return "assets"
    case .guardrailViolation: return "guardrail"
    case .unsupportedGuide: return "guide"
    case .unsupportedLanguageOrLocale: return "language"
    case .decodingFailure: return "decoding"
    case .rateLimited: return "rate-limit"
    case .concurrentRequests: return "concurrent"
    case .refusal: return "refusal"
    @unknown default: return "unknown"
    }
}

// 6) 动态 schema（运行时构造）
func dynamicSchema() throws -> GenerationSchema {
    let root = DynamicGenerationSchema(
        name: "Answer",
        properties: [
            .init(name: "label", schema: DynamicGenerationSchema(name: "label", anyOf: ["yes", "no"])),
            .init(name: "score", schema: DynamicGenerationSchema(type: Int.self, guides: [.range(0...100)]), isOptional: true),
        ]
    )
    return try GenerationSchema(root: root, dependencies: [])
}

// 7) 用例 / 护栏 / 适配器
func variants() throws {
    _ = SystemLanguageModel(useCase: .contentTagging)
    _ = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    let adapter = try SystemLanguageModel.Adapter(name: "MyAdapter")
    _ = SystemLanguageModel(adapter: adapter)
    _ = SystemLanguageModel.Adapter.compatibleAdapterIdentifiers(name: "MyAdapter")
}
