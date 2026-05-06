import Foundation
import Citadel
import NIOCore

// MARK: - Errors

public enum SFTPError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case timeout
    case commandFailed(String)
    case parseFailed(String)
    case fileNotFound(String)
    case permissionDenied(String)
    case alreadyConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to SFTP server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .timeout: return "Operation timed out"
        case .commandFailed(let msg): return "Command failed: \(msg)"
        case .parseFailed(let msg): return "Parse error: \(msg)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        case .alreadyConnected: return "Already connected"
        }
    }
}

// MARK: - Connection

/// Manages an SSH/SFTP connection using Citadel (pure Swift, built on SwiftNIO).
public actor SFTPConnection {
    private let config: ConnectionConfig
    private var client: SSHClient?
    private var sftpClient: SFTPClient?
    private var isConnected: Bool = false

    public init(config: ConnectionConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func connect(password: String? = nil) async throws {
        guard !isConnected else { throw SFTPError.alreadyConnected }

        do {
            let authMethod: @Sendable () -> SSHAuthenticationMethod
            let username = config.username

            switch config.authMethod {
            case .password:
                guard let pw = password, !pw.isEmpty else {
                    throw SFTPError.connectionFailed("Password auth requested but no password provided")
                }
                authMethod = { .passwordBased(username: username, password: pw) }

            case .sshKey:
                let keyPath = config.keyPath ?? "~/.ssh/id_rsa"
                let expandedPath = NSString(string: keyPath).expandingTildeInPath
                let keyData = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
                let privateKeyStr = String(data: keyData, encoding: .utf8) ?? ""
                let rsaKey = try Insecure.RSA.PrivateKey(sshRsa: privateKeyStr)
                authMethod = { .rsa(username: username, privateKey: rsaKey) }
            }

            let settings = SSHClientSettings(
                host: config.host,
                port: config.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything()
            )
            let sshClient = try await SSHClient.connect(to: settings)

            self.client = sshClient
            self.sftpClient = try await sshClient.openSFTP()
            self.isConnected = true
        } catch let error as SFTPError {
            throw error
        } catch {
            let message = error.localizedDescription
            if message.contains("Authentication") || message.contains("auth") {
                throw SFTPError.authenticationFailed
            }
            throw SFTPError.connectionFailed(message)
        }
    }

    public func disconnect() async {
        guard isConnected else { return }
        try? await sftpClient?.close()
        try? await client?.close()
        client = nil
        sftpClient = nil
        isConnected = false
    }

    // MARK: - Operations

    /// List contents of a remote directory.
    public func listDirectory(_ path: String) async throws -> [SFTPFile] {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            let names = try await sftp.listDirectory(atPath: path)

            // listDirectory returns [SFTPMessage.Name], each has .components: [SFTPPathComponent]
            return names.flatMap { name in
                name.components.compactMap { component -> SFTPFile? in
                    let filename = component.filename
                    guard filename != "." && filename != ".." else { return nil }

                    let attrs = component.attributes
                    let isDir = attrs.permissions.map { ($0 & 0o40000) != 0 } ?? false
                    let size = attrs.size ?? 0
                    let modDate = attrs.accessModificationTime?.modificationTime

                    let fullPath = path.hasSuffix("/")
                        ? path + filename
                        : path + "/" + filename

                    let perms = attrs.permissions.map { formatPermissions($0, isDirectory: isDir) }
                        ?? (isDir ? "drwxr-xr-x" : "-rw-r--r--")

                    return SFTPFile(
                        name: filename,
                        path: fullPath,
                        size: size,
                        isDirectory: isDir,
                        modificationDate: modDate,
                        permissions: perms
                    )
                }
            }
        } catch {
            throw mapSFTPError(error, path: path)
        }
    }

    /// Get file metadata.
    public func stat(_ path: String) async throws -> SFTPFile {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            let attributes = try await sftp.getAttributes(at: path)
            let name: String
            if let lastSlash = path.lastIndex(of: "/") {
                name = String(path[path.index(after: lastSlash)...])
            } else {
                name = path
            }

            let isDir = attributes.permissions.map { ($0 & 0o40000) != 0 } ?? false
            let size = attributes.size ?? 0
            let modDate = attributes.accessModificationTime?.modificationTime
            let perms = attributes.permissions.map { formatPermissions($0, isDirectory: isDir) }
                ?? (isDir ? "drwxr-xr-x" : "-rw-r--r--")

            return SFTPFile(
                name: name,
                path: path,
                size: size,
                isDirectory: isDir,
                modificationDate: modDate,
                permissions: perms
            )
        } catch {
            throw mapSFTPError(error, path: path)
        }
    }

    /// Download a remote file to a local path.
    public func readFile(_ remotePath: String, to localPath: String) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            let buffer = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                try await file.readAll()
            }
            let data = Data(buffer: buffer, byteTransferStrategy: .noCopy)
            try data.write(to: URL(fileURLWithPath: localPath))
        } catch {
            throw mapSFTPError(error, path: remotePath)
        }
    }

    /// Download a remote file returning its data.
    public func downloadFile(remotePath: String) async throws -> Data {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            let buffer = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                try await file.readAll()
            }
            return Data(buffer: buffer, byteTransferStrategy: .noCopy)
        } catch {
            throw mapSFTPError(error, path: remotePath)
        }
    }

    /// Upload data to a remote path.
    public func uploadFile(localData: Data, remotePath: String) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            let buffer = ByteBuffer(data: localData)
            try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
                try await file.write(buffer, at: 0)
            }
        } catch {
            throw mapSFTPError(error, path: remotePath)
        }
    }

    /// Write a local file to the remote server.
    public func writeFile(from localPath: String, to remotePath: String) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
        try await uploadFile(localData: data, remotePath: remotePath)
    }

    /// Create a remote directory.
    public func mkdir(_ path: String) async throws {
        try await createDirectory(at: path)
    }

    /// Create a remote directory.
    public func createDirectory(at path: String) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            throw mapSFTPError(error, path: path)
        }
    }

    /// Remove a remote file or directory.
    public func remove(_ path: String) async throws {
        try await deleteItem(at: path, isDirectory: false)
    }

    /// Delete a remote item.
    public func deleteItem(at path: String, isDirectory: Bool) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            if isDirectory {
                try await sftp.rmdir(at: path)
            } else {
                try await sftp.remove(at: path)
            }
        } catch {
            throw mapSFTPError(error, path: path)
        }
    }

    /// Rename/move a remote file or directory.
    public func rename(from oldPath: String, to newPath: String) async throws {
        try await moveItem(from: oldPath, to: newPath)
    }

    /// Move/rename a remote item.
    public func moveItem(from oldPath: String, to newPath: String) async throws {
        guard let sftp = sftpClient else { throw SFTPError.notConnected }

        do {
            try await sftp.rename(at: oldPath, to: newPath)
        } catch {
            throw mapSFTPError(error, path: oldPath)
        }
    }

    // MARK: - Private Helpers

    private func mapSFTPError(_ error: Error, path: String) -> SFTPError {
        let message = String(describing: error)
        if message.contains("No such file") || message.contains("not found") || message.contains("doesNotExist") {
            return .fileNotFound(path)
        }
        if message.contains("Permission denied") || message.contains("permissionDenied") {
            return .permissionDenied(path)
        }
        return .commandFailed(message)
    }

    private func formatPermissions(_ permissions: UInt32, isDirectory: Bool) -> String {
        let typeChar: Character = isDirectory ? "d" : "-"
        let rwx = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        let owner = rwx[Int((permissions >> 6) & 0o7)]
        let group = rwx[Int((permissions >> 3) & 0o7)]
        let other = rwx[Int(permissions & 0o7)]
        return "\(typeChar)\(owner)\(group)\(other)"
    }
}
