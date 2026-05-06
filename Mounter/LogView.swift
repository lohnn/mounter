import SwiftUI

struct LogView: View {
    @ObservedObject private var logStore = LogStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button("Clear") { logStore.clear() }
                    .buttonStyle(.borderless)
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                List(logStore.entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(for: entry.level))
                    }
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: logStore.entries.count) { _ in
                    if let last = logStore.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 150)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .yellow
        case .error: return .red
        }
    }
}
