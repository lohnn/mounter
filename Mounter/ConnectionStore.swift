import Foundation
import FileProvider
import Combine

enum ConnectionState {
    case disconnected, connecting, connected, error
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private var states: [UUID: ConnectionState] = [:]

    private static let appGroupIdentifier = "group.se.lohnn.mounter"
    private static let configsFileName = "connections.json"

    private let fileURL: URL

    init() {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        )!
        self.fileURL = containerURL.appendingPathComponent(Self.configsFileName)
        load()
    }

    // MARK: - Public

    func state(for id: UUID) -> ConnectionState {
        states[id] ?? .disconnected
    }

    func add(_ config: ConnectionConfig) {
        connections.append(config)
        states[config.id] = .disconnected
        save()
        LogStore.shared.log("Added connection: \(config.displayName)")
    }

    func remove(_ config: ConnectionConfig) {
        unmount(config)
        connections.removeAll { $0.id == config.id }
        states.removeValue(forKey: config.id)
        KeychainHelper.delete(account: config.id.uuidString)
        save()
        LogStore.shared.log("Removed connection: \(config.displayName)")
    }

    func update(_ config: ConnectionConfig) {
        guard let idx = connections.firstIndex(where: { $0.id == config.id }) else { return }
        connections[idx] = config
        save()
    }

    func mount(_ config: ConnectionConfig) {
        states[config.id] = .connecting
        LogStore.shared.log("Mounting \(config.displayName)...")
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: config.id.uuidString),
            displayName: config.displayName
        )
        NSFileProviderManager.add(domain) { [weak self] error in
            Task { @MainActor in
                if let error {
                    LogStore.shared.log("Mount failed for \(config.displayName): \(error.localizedDescription)", level: .error)
                    self?.states[config.id] = .error
                } else {
                    LogStore.shared.log("Mounted \(config.displayName) successfully")
                    self?.states[config.id] = .connected
                }
            }
        }
    }

    func testConnection(_ config: ConnectionConfig) async -> (Bool, String) {
        LogStore.shared.log("Testing connection to \(config.displayName)...")
        let connection = SFTPConnection(config: config)
        do {
            let password = KeychainHelper.load(account: config.id.uuidString)
            try await connection.connect(password: password)
            let items = try await connection.listDirectory("/")
            await connection.disconnect()
            let message = "Connected, \(items.count) items in root"
            LogStore.shared.log("Test succeeded for \(config.displayName): \(message)")
            return (true, message)
        } catch {
            await connection.disconnect()
            let message = error.localizedDescription
            LogStore.shared.log("Test failed for \(config.displayName): \(message)", level: .error)
            return (false, message)
        }
    }

    func unmount(_ config: ConnectionConfig) {
        LogStore.shared.log("Unmounting \(config.displayName)...")
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: config.id.uuidString),
            displayName: config.displayName
        )
        NSFileProviderManager.remove(domain) { [weak self] error in
            Task { @MainActor in
                if let error {
                    LogStore.shared.log("Unmount error for \(config.displayName): \(error.localizedDescription)", level: .warning)
                }
                self?.states[config.id] = .disconnected
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else { return }
        connections = decoded
        for c in connections { states[c.id] = .disconnected }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
