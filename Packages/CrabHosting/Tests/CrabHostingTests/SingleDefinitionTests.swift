import XCTest

/// pro 的 M2:承载 origin「在端内只定义一处」,其判据是**一条可执行检查**(单测或构建期脚本,
/// 走查不算)。这条就是那条检查:扫生产源码树,断言承载 origin 整串只出现一次 —— 就在
/// `HostingOrigin.origin` 那一行。多写一处,改 origin 时会漏,而漏掉的表现是静默的(脚本不注入、
/// 导航被误拦)。
///
/// 扫的范围是生产代码:`App/` 与 `Packages/CrabHosting/Sources/`。**不扫 `Spikes/`** —— 它是插队
/// 核实的一次性产物(`project.yml` 与 `CLAUDE.md` 都写明它不是实现),里面为了并排比较三种形状
/// 本就刻意写了多个字面量,不受这条约束。也不扫本测试文件:needle 用拼接构造,源文件里不出现整串。
final class SingleDefinitionTests: XCTestCase {
    func test_承载origin在生产源码里只定义一处() throws {
        // 拼出来,避免本文件自己命中。
        let needle = "crab:" + "//ios.crab.invalid"

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CrabHostingTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CrabHosting
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // <repo root>

        let scanDirs = [
            repoRoot.appendingPathComponent("App"),
            repoRoot.appendingPathComponent("Packages/CrabHosting/Sources"),
        ]

        var hits: [String] = []
        let fm = FileManager.default
        for dir in scanDirs {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let count = text.components(separatedBy: needle).count - 1
                for _ in 0..<count { hits.append(url.lastPathComponent) }
            }
        }

        XCTAssertEqual(
            hits.count, 1,
            "承载 origin 应只定义一处(HostingOrigin.origin),实际出现在:\(hits)"
        )
    }
}
