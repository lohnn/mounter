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
    public var remotePath: String

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
        keyPath: String? = nil,
        remotePath: String = "/"
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyPath = keyPath
        self.remotePath = remotePath
    }

    // MARK: - Codable (backward compatibility)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, authMethod, keyPath, remotePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath)
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? "/"
    }
}
