import Foundation
import Observation
import OSLog

/// 收结果、落文件、打日志。三条出口都留着，是因为「从命令行回读得到什么」本身也是要试的事：
/// 文件那条最可靠（`simctl get_app_container` 直接读），`print` 那条 `simctl launch --console-pty`
/// 收得到，`Logger` 那条是 M4 那五条靠日志判的断言要走的路，顺带在这里试一次。
@MainActor
@Observable
final class ProbeModel {
    private(set) var results: [String: String] = [:]
    private let logger = Logger(subsystem: "net.xiaoluzhu.crab", category: "spike")

    /// 落盘文件名，`scripts/spike-origin.sh` 按这个名字回读。
    static let fileName = "spike-origin.txt"

    var report: String {
        OriginProbe.shapes
            .map { "\($0.id)\n\(results[$0.id] ?? "（还没回来）")\n" }
            .joined(separator: "\n")
    }

    func record(shape: String, json: String) {
        results[shape] = json
        let line = "CRAB-SPIKE \(shape) \(json)"
        print(line)
        logger.log("\(line, privacy: .public)")
        flush()
    }

    /// 每收到一条就重写一次：只写「全都回来了」会在某一形状卡住时什么都留不下。
    private func flush() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var text = "# 插队核实 · 承载 origin 形态\n# \(stamp)\n"
        for shape in OriginProbe.shapes {
            text += "\n\(shape.id) \(shape.url)\n\(results[shape.id] ?? "（还没回来）")\n"
        }

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        do {
            try text.write(to: dir.appendingPathComponent(Self.fileName), atomically: true, encoding: .utf8)
        } catch {
            print("CRAB-SPIKE write-failed \(error)")
        }
    }
}
