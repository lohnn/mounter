import Foundation
import Darwin

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

    public func connect(password: String? = nil) async throws {
        guard !isConnected else { throw SFTPError.alreadyConnected }

        switch config.authMethod {
        case .password:
            try await connectWithPassword(password)
        case .sshKey:
            try await connectWithKey()
        }
    }

    private func connectWithPassword(_ password: String?) async throws {
        // Use a real PTY so sftp gets an interactive terminal and prompts for password
        var primary: Int32 = 0
        var secondary: Int32 = 0
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        let result = openpty(&primary, &secondary, nil, nil, &winSize)
        guard result == 0 else {
            throw SFTPError.connectionFailed("Failed to allocate PTY")
        }

        let args = [
            "/usr/bin/sftp",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityFile=/dev/null",
            "-P", "\(config.port)",
            "\(config.username)@\(config.host)"
        ]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        proc.arguments = Array(args.dropFirst()) // drop the executable path

        // Connect the secondary (child) side of the PTY to the process
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: false)
        proc.standardInput = secondaryHandle
        proc.standardOutput = secondaryHandle
        proc.standardError = secondaryHandle

        do {
            try proc.run()
        } catch {
            close(primary)
            close(secondary)
            throw SFTPError.connectionFailed(error.localizedDescription)
        }

        // Close the secondary side in the parent process
        close(secondary)

        // Use the primary side for reading/writing
        let primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        self.process = proc
        self.stdin = primaryHandle
        self.stdout = primaryHandle

        // Wait for password prompt
        print("[SFTPConnection] Waiting for password prompt...")
        do {
            try await waitForPasswordPrompt(timeout: Self.defaultTimeout)
        } catch {
            let buffered = outputBuffer
            cleanup()
            throw SFTPError.connectionFailed("Never received password prompt. Output so far: \(buffered.prefix(300))")
        }

        guard let pw = password, !pw.isEmpty else {
            cleanup()
            throw SFTPError.connectionFailed("Password auth requested but no password provided")
        }

        print("[SFTPConnection] Sending password...")
        sendRaw(pw + "\n")

        // Wait for sftp> prompt
        print("[SFTPConnection] Waiting for sftp> prompt...")
        do {
            _ = try await readUntilPrompt()
            isConnected = true
            print("[SFTPConnection] Connected successfully.")
        } catch {
            let buffered = outputBuffer
            cleanup()
            if buffered.contains("Permission denied") || buffered.contains("Authentication failed") {
                throw SFTPError.authenticationFailed
            }
            throw SFTPError.connectionFailed("Failed waiting for sftp> prompt. Output so far: \(buffered.prefix(300))")
        }
    }

    private func connectWithKey() async throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stdoutPipe

        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        let keyFile = config.keyPath ?? "~/.ssh/id_rsa"
        proc.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-i", keyFile,
            "-P", "\(config.port)",
            "\(config.username)@\(config.host)"
        ]

        do {
            try proc.run()
        } catch {
            throw SFTPError.connectionFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        // Wait for initial sftp> prompt
        do {
            _ = try await readUntilPrompt()
            isConnected = true
        } catch {
            let buffered = outputBuffer
            cleanup()
            if buffered.contains("Permission denied") {
                throw SFTPError.authenticationFailed
            }
            throw SFTPError.connectionFailed("Failed waiting for sftp> prompt. Output so far: \(buffered.prefix(300))")
        }
    }

        do {
            try proc.run()
        } catch {
            throw SFTPError.connectionFailed(error.localizedDescription)
        }

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        // If password auth, wait for "password:" prompt and send password
        if needsPasswordAuth {
            print("[SFTPConnection] Waiting for password prompt...")
            do {
                try await waitForPasswordPrompt(timeout: Self.defaultTimeout)
            } catch {
                let buffered = outputBuffer
                cleanup()
                throw SFTPError.connectionFailed("Never received password prompt. Output so far: \(buffered.prefix(300))")
            }

            guard let pw = password, !pw.isEmpty else {
                cleanup()
                throw SFTPError.connectionFailed("Password auth requested but no password provided")
            }

            print("[SFTPConnection] Sending password...")
            sendRaw(pw + "\n")
        }

        // Wait for initial sftp> prompt
        print("[SFTPConnection] Waiting for sftp> prompt...")
        do {
            _ = try await readUntilPrompt()
            isConnected = true
            print("[SFTPConnection] Connected successfully.")
        } catch {
            let buffered = outputBuffer
            cleanup()
            if buffered.contains("Permission denied") || buffered.contains("Authentication failed") {
                throw SFTPError.authenticationFailed
            }
            throw SFTPError.connectionFailed("Failed waiting for sftp> prompt. Output so far: \(buffered.prefix(200))")
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

    private func waitForPasswordPrompt(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let data = stdout?.availableData, !data.isEmpty {
                if let chunk = String(data: data, encoding: .utf8) {
                    outputBuffer += chunk
                }
            }

            // Look for common password prompt patterns
            let lower = outputBuffer.lowercased()
            if lower.contains("password:") || lower.contains("password: ") {
                // Clear the buffer up to and including the prompt
                // (we don't want the password prompt leaking into command output)
                if let range = outputBuffer.range(of: "assword:", options: .caseInsensitive) {
                    outputBuffer = String(outputBuffer[range.upperBound...])
                }
                return
            }

            // If process died, bail
            if process?.isRunning == false {
                throw SFTPError.connectionFailed("sftp process exited before password prompt. Output: \(outputBuffer.prefix(200))")
            }

            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        throw SFTPError.timeout
    }
}
