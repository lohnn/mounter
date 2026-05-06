import Foundation

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

/// Manages a persistent sftp subprocess for file operations.
public actor SFTPConnection {
    private let config: ConnectionConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var outputBuffer: String = ""
    private var isConnected: Bool = false

    private static let prompt = "sftp>"
    private static let defaultTimeout: TimeInterval = 30

    public init(config: ConnectionConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard !isConnected else { throw SFTPError.alreadyConnected }

        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        switch config.auth {
        case .password(let password):
            // Use SSH_ASKPASS trick for non-interactive password auth
            let askpassScript = createAskpassScript(password: password)
            proc.environment = [
                "SSH_ASKPASS": askpassScript,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": ":0"
            ]
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            proc.arguments = [
                "-o", "StrictHostKeyChecking=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-P", "\(config.port)",
                config.sftpTarget
            ]
        case .key(let path, _):
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            proc.arguments = [
                "-o", "StrictHostKeyChecking=no",
                "-o", "BatchMode=yes",
                "-i", path,
                "-P", "\(config.port)",
                config.sftpTarget
            ]
        }

        do {
            try proc.run()
        } catch {
            throw SFTPError.connectionFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        // Wait for initial prompt
        do {
            _ = try await readUntilPrompt()
            isConnected = true
        } catch {
            cleanup()
            throw SFTPError.authenticationFailed
        }
    }

    public func disconnect() {
        guard isConnected else { return }
        sendRaw("bye\n")
        cleanup()
    }

    public func reconnect() async throws {
        disconnect()
        try await connect()
    }

    // MARK: - Operations

    /// List contents of a remote directory.
    public func listDirectory(_ path: String) async throws -> [SFTPFile] {
        let output = try await execute("ls -la \(escapePath(path))")
        let lines = output.components(separatedBy: .newlines)
        return lines.compactMap { SFTPFile.parse(line: $0, parentPath: path) }
    }

    /// Get file metadata.
    public func stat(_ path: String) async throws -> SFTPFile {
        // Use ls -la on the parent directory and find the entry
        let parentPath: String
        let fileName: String
        if let lastSlash = path.lastIndex(of: "/") {
            parentPath = String(path[path.startIndex...lastSlash])
            fileName = String(path[path.index(after: lastSlash)...])
        } else {
            parentPath = "."
            fileName = path
        }

        let entries = try await listDirectory(parentPath)
        guard let entry = entries.first(where: { $0.name == fileName }) else {
            throw SFTPError.fileNotFound(path)
        }
        return entry
    }

    /// Read a remote file, returning its contents.
    public func readFile(_ remotePath: String, to localPath: String) async throws {
        let output = try await execute("get \(escapePath(remotePath)) \(escapePath(localPath))")
        if output.contains("not found") || output.contains("No such file") {
            throw SFTPError.fileNotFound(remotePath)
        }
        if output.contains("Permission denied") {
            throw SFTPError.permissionDenied(remotePath)
        }
    }

    /// Write a local file to the remote server.
    public func writeFile(from localPath: String, to remotePath: String) async throws {
        let output = try await execute("put \(escapePath(localPath)) \(escapePath(remotePath))")
        if output.contains("Permission denied") {
            throw SFTPError.permissionDenied(remotePath)
        }
    }

    /// Create a remote directory.
    public func mkdir(_ path: String) async throws {
        let output = try await execute("mkdir \(escapePath(path))")
        if output.contains("Permission denied") {
            throw SFTPError.permissionDenied(path)
        }
        if output.contains("Failure") {
            throw SFTPError.commandFailed("mkdir failed: \(output)")
        }
    }

    /// Remove a remote file or directory.
    public func remove(_ path: String) async throws {
        // Try rm first (file), then rmdir (directory)
        let output = try await execute("rm \(escapePath(path))")
        if output.contains("not a regular file") || output.contains("Is a directory") {
            let rmdirOutput = try await execute("rmdir \(escapePath(path))")
            if rmdirOutput.contains("Failure") || rmdirOutput.contains("not empty") {
                throw SFTPError.commandFailed("remove failed: \(rmdirOutput)")
            }
        } else if output.contains("No such file") || output.contains("not found") {
            throw SFTPError.fileNotFound(path)
        } else if output.contains("Permission denied") {
            throw SFTPError.permissionDenied(path)
        }
    }

    /// Rename/move a remote file or directory.
    public func rename(from oldPath: String, to newPath: String) async throws {
        let output = try await execute("rename \(escapePath(oldPath)) \(escapePath(newPath))")
        if output.contains("No such file") || output.contains("not found") {
            throw SFTPError.fileNotFound(oldPath)
        }
        if output.contains("Permission denied") {
            throw SFTPError.permissionDenied(oldPath)
        }
        if output.contains("Failure") {
            throw SFTPError.commandFailed("rename failed: \(output)")
        }
    }

    // MARK: - Private

    private func execute(_ command: String) async throws -> String {
        guard isConnected, process?.isRunning == true else {
            throw SFTPError.notConnected
        }
        sendRaw(command + "\n")
        return try await readUntilPrompt()
    }

    private func sendRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        stdin?.write(data)
    }

    private func readUntilPrompt(timeout: TimeInterval = defaultTimeout) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let data = stdout?.availableData, !data.isEmpty {
                if let chunk = String(data: data, encoding: .utf8) {
                    outputBuffer += chunk
                }
            }

            if let promptRange = outputBuffer.range(of: Self.prompt) {
                let result = String(outputBuffer[outputBuffer.startIndex..<promptRange.lowerBound])
                outputBuffer = String(outputBuffer[promptRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Check for error indicators before prompt
            if outputBuffer.contains("Permission denied") && !process!.isRunning {
                let msg = outputBuffer
                outputBuffer = ""
                throw SFTPError.authenticationFailed
            }

            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        throw SFTPError.timeout
    }

    private func cleanup() {
        isConnected = false
        stdin?.closeFile()
        stdout?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        stdin = nil
        stdout = nil
        outputBuffer = ""
    }

    private func escapePath(_ path: String) -> String {
        // Wrap in quotes, escaping internal quotes
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func createAskpassScript(password: String) -> String {
        let dir = NSTemporaryDirectory()
        let scriptPath = (dir as NSString).appendingPathComponent("sftp_askpass_\(UUID().uuidString).sh")
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let content = "#!/bin/sh\necho '\(escaped)'\n"
        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8), attributes: [.posixPermissions: 0o700])
        return scriptPath
    }
}
