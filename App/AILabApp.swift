import SwiftUI
import AICore
import AIFeatures

@main
struct AILabApp: App {
    /// 装配在这里发生一次。换成真实云端提供方时只改 `ProviderFactory`，视图不动。
    @State private var store = ChatStore(provider: ProviderFactory.makeDefaultRouter())

    var body: some Scene {
        WindowGroup {
            ChatView(store: store)
        }
    }
}
