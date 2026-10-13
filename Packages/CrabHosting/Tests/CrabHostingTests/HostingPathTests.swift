import XCTest
@testable import CrabHosting

/// 路径归一化是「不得读到承载目录之外的文件」那条判据里**单测证明的那一半**(另一半是模拟器上
/// `escape` / `escape-encoded` 两条断言)。pro 的 M2:「路径归一化本身仍靠单测证明」。
final class HostingPathTests: XCTestCase {
    func test_普通路径原样落在承载目录内() {
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/index.html"), "index.html")
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/probe.js"), "probe.js")
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/a/b/c.png"), "a/b/c.png")
    }

    func test_根与点段归一化到入口() {
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/"), "")
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/./index.html"), "index.html")
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/a/./b.js"), "a/b.js")
    }

    func test_明文越界被拒() {
        XCTAssertNil(HostingPath.resolve(percentEncodedPath: "/../out-of-bounds.txt"))
        XCTAssertNil(HostingPath.resolve(percentEncodedPath: "/a/../../out-of-bounds.txt"))
    }

    func test_编码越界被拒() {
        // %2e%2e%2f == ../  。解码后同样被按段消解拦住。
        XCTAssertNil(HostingPath.resolve(percentEncodedPath: "/%2e%2e%2fout-of-bounds.txt"))
        XCTAssertNil(HostingPath.resolve(percentEncodedPath: "/%2e%2e/out-of-bounds.txt"))
        // 双重编码:%252e → %2e → 这里只解一层,留给 handler 不命中走 404,仍不泄漏。
        // 单层解码后是字面 "%2e%2e"(不是 ".."),当成普通段,映射到承载目录内一个不存在的文件。
        XCTAssertEqual(
            HostingPath.resolve(percentEncodedPath: "/%252e%252e%252fout-of-bounds.txt"),
            "%2e%2e%2fout-of-bounds.txt"
        )
    }

    func test_同级往上刚好回到根不算越界() {
        // a/.. 回到根,合法;再多一个 .. 才越界。
        XCTAssertEqual(HostingPath.resolve(percentEncodedPath: "/a/../index.html"), "index.html")
        XCTAssertNil(HostingPath.resolve(percentEncodedPath: "/a/../../index.html"))
    }

    func test_host判定从承载host派生() {
        XCTAssertTrue(HostingPath.isHostingHost(HostingOrigin.host))
        XCTAssertFalse(HostingPath.isHostingHost("evil.example"))
        XCTAssertFalse(HostingPath.isHostingHost(nil))
        XCTAssertFalse(HostingPath.isHostingHost(""))
    }
}
