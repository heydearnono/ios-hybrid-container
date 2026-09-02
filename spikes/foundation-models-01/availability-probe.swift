import FoundationModels
import Foundation

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let model = SystemLanguageModel.default
switch model.availability {
case .available: log("availability: available")
case .unavailable(let reason): log("availability: unavailable(\(reason))")
@unknown default: log("availability: unknown")
}
log("isAvailable: \(model.isAvailable)")
log("supportedLanguages(count=\(model.supportedLanguages.count)): \(model.supportedLanguages.map(\.minimalIdentifier).sorted())")
log("supportsLocale(zh_CN): \(model.supportsLocale(Locale(identifier: "zh_CN")))")
log("supportsLocale(en_US): \(model.supportsLocale(Locale(identifier: "en_US")))")

log("--- forcing respond() despite unavailable, to see if it throws or hangs ---")

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        let session = LanguageModelSession(instructions: "Reply in one short sentence.")
        let start = Date()
        let r = try await session.respond(to: "Say hello.")
        log("respond OK in \(String(format: "%.2f", Date().timeIntervalSince(start)))s: \(r.content)")
    } catch let e as LanguageModelSession.GenerationError {
        log("GenerationError: \(e)")
    } catch {
        log("error: \(error)")
    }
    sema.signal()
}
if sema.wait(timeout: .now() + 90) == .timedOut {
    log("respond() TIMED OUT after 90s")
}
exit(0)
