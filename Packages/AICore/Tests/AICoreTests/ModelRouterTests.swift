import Testing
import Foundation
@testable import AICore

private let cloudID: ModelProviderID = "cloud"
private let onDeviceID: ModelProviderID = "on-device"

private func makeCloud(_ behavior: MockBehavior) -> MockLanguageModelProvider {
    MockLanguageModelProvider(id: cloudID, isOnDevice: false, behavior: behavior)
}

private func makeOnDevice(_ behavior: MockBehavior) -> MockLanguageModelProvider {
    MockLanguageModelProvider(id: onDeviceID, isOnDevice: true, behavior: behavior)
}

@Suite("路由：云端为主，端侧增强")
struct ModelRouterTests {
    @Test("云端可用时走云端")
    func prefersPrimary() async throws {
        let cloud = makeCloud(MockBehavior(replies: ["来自云端"]))
        let onDevice = makeOnDevice(MockBehavior(replies: ["来自端侧"]))
        let router = ModelRouter(primary: cloud, onDevice: onDevice)

        let response = try await router.respond(to: ModelRequest(prompt: "hi"))

        #expect(response.text == "来自云端")
        #expect(await router.lastDecision?.providerID == cloudID)
        #expect(await router.lastDecision?.reason == .primaryAvailable)
        #expect(await onDevice.recordedRequests.isEmpty)
    }

    @Test("云端不可用时降级到端侧，并记录降级原因")
    func fallsBackToOnDevice() async throws {
        let cloud = makeCloud(MockBehavior(availability: .unavailable(.notConfigured)))
        let onDevice = makeOnDevice(MockBehavior(replies: ["来自端侧"]))
        let router = ModelRouter(primary: cloud, onDevice: onDevice)

        let response = try await router.respond(to: ModelRequest(prompt: "hi"))

        #expect(response.text == "来自端侧")
        #expect(await router.lastDecision?.reason
                == .fellBackToOnDevice(primaryReason: .notConfigured))
        #expect(await cloud.recordedRequests.isEmpty)
    }

    @Test("两条路都不可用时抛出主线的不可用原因")
    func throwsWhenBothUnavailable() async throws {
        let cloud = makeCloud(MockBehavior(availability: .unavailable(.notConfigured)))
        let onDevice = makeOnDevice(MockBehavior(availability: .unavailable(.modelNotReady)))
        let router = ModelRouter(primary: cloud, onDevice: onDevice)

        await #expect(throws: ModelError.unavailable(.notConfigured)) {
            _ = try await router.respond(to: ModelRequest(prompt: "hi"))
        }
    }

    @Test("onDeviceOnly 在端侧不可用时直接失败，绝不降级到云端")
    func neverSilentlyFallsBackToCloud() async throws {
        let cloud = makeCloud(MockBehavior(replies: ["云端本不该看到这个请求"]))
        let onDevice = makeOnDevice(MockBehavior(availability: .unavailable(.modelNotReady)))
        let router = ModelRouter(primary: cloud, onDevice: onDevice)

        let request = ModelRequest(prompt: "隐私数据", privacy: .onDeviceOnly)
        await #expect(throws: ModelError.unavailable(.modelNotReady)) {
            _ = try await router.respond(to: request)
        }

        // 关键不变量：请求一次都没有到达云端。
        #expect(await cloud.recordedRequests.isEmpty)
    }

    @Test("没有配置端侧提供方时，onDeviceOnly 报 notConfigured 而不是打到云端")
    func onDeviceOnlyWithoutOnDeviceProvider() async throws {
        let cloud = makeCloud(MockBehavior())
        let router = ModelRouter(primary: cloud)

        let request = ModelRequest(prompt: "隐私数据", privacy: .onDeviceOnly)
        await #expect(throws: ModelError.unavailable(.notConfigured)) {
            _ = try await router.respond(to: request)
        }
        #expect(await cloud.recordedRequests.isEmpty)
    }

    @Test("只要有一条路可走，整体就算可用")
    func availabilityIsAggregated() async throws {
        let cloud = makeCloud(MockBehavior(availability: .unavailable(.notConfigured)))
        let onDevice = makeOnDevice(MockBehavior())
        #expect(await ModelRouter(primary: cloud, onDevice: onDevice).availability()
                == .available)

        let deadOnDevice = makeOnDevice(MockBehavior(availability: .unavailable(.modelNotReady)))
        #expect(await ModelRouter(primary: cloud, onDevice: deadOnDevice).availability()
                == .unavailable(.notConfigured))
    }
}
