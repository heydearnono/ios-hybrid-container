import SwiftUI
import AICore
import AIFeatures

struct ChatView: View {
    @Bindable var store: ChatStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                transcript
                composer
            }
            .navigationTitle("AI Lab")
            .task { await store.refreshAvailability() }
        }
    }

    // MARK: - 状态条

    @ViewBuilder
    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let availability = store.availability {
                Label {
                    Text(availabilityText(availability))
                } icon: {
                    Image(systemName: availability.isAvailable
                          ? "checkmark.circle" : "exclamationmark.triangle")
                }
                .font(.footnote)
                .foregroundStyle(availability.isAvailable ? Color.secondary : Color.orange)
            }
            if let note = store.routingNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("错误：\(error)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func availabilityText(_ availability: ModelAvailability) -> String {
        switch availability {
        case .available:
            return "模型可用"
        case .unavailable(let reason):
            return "模型不可用：\(reason)"
        }
    }

    // MARK: - 消息列表

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if store.messages.isEmpty {
                    Text("发一条消息试试。当前云端提供方是替身实现，端侧在本机不可用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
                ForEach(store.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("输入消息", text: $store.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(store.isResponding)
                .onSubmit { Task { await store.send() } }

            Button {
                Task { await store.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!store.canSend)
            .accessibilityLabel("发送")
        }
        .padding()
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .user ? "我" : "助手")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(message.text)
                .textSelection(.enabled)
            if message.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("正在生成回答")
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .multilineTextAlignment(message.role == .user ? .trailing : .leading)
    }
}
