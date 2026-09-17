import SwiftUI

/// M1 的全部内容：一个能装进模拟器、起得来、屏幕上有东西的原生壳子。
///
/// **这一步不碰 WebView。** 承载、注入、导航、降级分别是 M2 到 M4 的事，
/// 判据在 pro 的 `plan/` 里，本仓不复述。
@main
struct CrabApp: App {
    init() {
        // 冒烟测试靠进程存活判定，这行只是让「起来了」在命令行里也看得见一次。
        print("CRAB-M1 launched \(AppMetadata.bundleIdentifier) \(AppMetadata.version)")
    }

    var body: some Scene {
        WindowGroup {
            // 唯一的一处分叉：带 `--spike-origin` 起来就跑插队核实那一页。
            // 一次性验证代码不另起临时工程，但也不许挤进正常路径。
            if ProcessInfo.processInfo.arguments.contains("--spike-origin") {
                OriginProbeView()
            } else {
                HomeView()
            }
        }
    }
}
