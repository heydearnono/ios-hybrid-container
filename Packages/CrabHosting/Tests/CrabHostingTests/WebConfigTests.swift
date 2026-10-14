import XCTest
@testable import CrabHosting

/// M3「取值类与 UA 拼接靠单测」那一类的单测。iOS 的框架对象取值在宿主上测不了,所以测的是:
/// UA 标记的拼接结果、六项配置的意图取值、以及注入脚本的形状(三端一字不差的那几件)。
final class WebConfigTests: XCTestCase {
    func test_UA标记拼成Crab版本() {
        XCTAssertEqual(CrabUserAgent.marker, "Crab")
        XCTAssertEqual(CrabUserAgent.applicationName(version: "0.1.0"), "Crab/0.1.0")
        // 换一个版本号,形状仍是 <标记>/<版本>,不写死 0.1.0。
        XCTAssertEqual(CrabUserAgent.applicationName(version: "1.2.3"), "Crab/1.2.3")
    }

    func test_六项配置的意图取值() {
        XCTAssertTrue(WebConfigSpec.javaScriptEnabled)
        XCTAssertTrue(WebConfigSpec.domStorageEnabled)
        XCTAssertFalse(WebConfigSpec.allowsHTTPSubresources)
        XCTAssertFalse(WebConfigSpec.fileAccessEnabled)
        XCTAssertTrue(WebConfigSpec.audioAutoplayRequiresUserGesture)
        XCTAssertFalse(WebConfigSpec.zoomEnabled)
    }

    func test_注入脚本的形状() {
        let origin = HostingOrigin.origin
        let script = WebInjection.documentStartScript(origin: origin)

        // 先判 origin:不是承载 origin 就返回(「不越出承载 origin」在 iOS 落在脚本自身)。
        XCTAssertTrue(script.contains("location.origin !== '\(origin)'"))
        XCTAssertTrue(script.contains("return;"))
        // 建对象 + 自增,不是重置(跑两次要看得出来)。
        XCTAssertTrue(script.contains("window.__CRAB__ = window.__CRAB__ || { origin: location.origin, injected: 0 }"))
        XCTAssertTrue(script.contains("window.__CRAB__.injected++"))
    }

    func test_注入脚本的origin从参数来不写死() {
        // 换一个 origin,脚本跟着变 —— 证明没把 HostingOrigin 之外的字面量焊死在脚本里。
        let script = WebInjection.documentStartScript(origin: "crab://other.example")
        XCTAssertTrue(script.contains("location.origin !== 'crab://other.example'"))
        XCTAssertFalse(script.contains("ios.crab.invalid"))
    }
}
