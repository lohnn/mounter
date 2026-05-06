import Foundation

enum LogLevel: String {
    case info, warning, error
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
}

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published var entries: [LogEntry] = []

    private init() {}

    func log(_ message: String, level: LogLevel = .info) {
        entries.append(LogEntry(timestamp: Date(), level: level, message: message))
    }

    func clear() {
        entries.removeAll()
    }
}
