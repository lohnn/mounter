import Foundation

/// Shared model representing a saved SFTP connection.
public struct ConnectionConfig: Identifiable, Codable, Hashable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    public var keyPath: String?

    public enum AuthMethod: String, Codable, Hashable {
        case password
        case sshKey
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .password,
        keyPath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyPath = keyPath
    }
}
