import Testing
import AppIntents
@testable import IntentKit

// 要回答的问题：定义在 SPM 包里的 AppIntent，能不能在**宿主 macOS 上**用 swift test
// 直接实例化并调用 perform()？（不进模拟器、不进 App target）

@Test func 纯逻辑层可直接测试() {
    let out = Summarizer().summarize("one two three four five six", maxWords: 3)
    #expect(out == "one two three")
}

@Test func AppIntent可以在宿主上实例化并手工赋参() async throws {
    let intent = SummarizeIntent()
    intent.text = "alpha beta gamma delta epsilon"
    intent.maxWords = 4
    intent.style = .verbose

    #expect(intent.text == "alpha beta gamma delta epsilon")
    #expect(intent.maxWords == 4)
    #expect(intent.style == .verbose)
}

@Test func 直接调用perform并读出返回值() async throws {
    let intent = SummarizeIntent()
    intent.text = "alpha beta gamma delta epsilon"
    intent.maxWords = 4
    intent.style = .verbose

    let result = try await intent.perform()
    #expect(result.value == "alpha beta gamma delta")
}

@Test func terse风格会把上限压到3() async throws {
    let intent = SummarizeIntent()
    intent.text = "alpha beta gamma delta epsilon"
    intent.maxWords = 4
    intent.style = .terse

    let result = try await intent.perform()
    #expect(result.value == "alpha beta gamma")
}
