import SwiftUI

/// M1 的原生页面：证明产物装得上、起得来、屏幕上有东西。
///
/// 之所以顺手把标识与版本打在屏上，是因为这两项要和 pro 的取值表逐字对齐，
/// 而 `verify.sh` 只查产物里的 Info.plist —— 屏上这一份是给人看的第二眼。
struct HomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("🦀")
                .font(.system(size: 64))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(AppMetadata.displayName)
                    .font(.largeTitle.bold())
                Text("三端 WebView 容器 · iOS")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                row("标识", AppMetadata.bundleIdentifier)
                row("版本", AppMetadata.version)
                row("系统", AppMetadata.systemVersion)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: .rect(cornerRadius: 12))

            Text("M1 · 装到模拟器")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .multilineTextAlignment(.center)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontDesign(.monospaced)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HomeView()
}
