import SwiftUI
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    enum Mode { case add, edit(ConnectionConfig) }

    let mode: Mode
    let onSave: (ConnectionConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var store: ConnectionStore

    @State private var displayName = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = ""
    @State private var authMethod: ConnectionConfig.AuthMethod = .password
    @State private var password = ""
    @State private var keyPath = ""
    @State private var remotePath = "/"
    @State private var isTesting = false
    @State private var testResult: String?

    init(mode: Mode, onSave: @escaping (ConnectionConfig) -> Void) {
        self.mode = mode
        self.onSave = onSave
        if case .edit(let config) = mode {
            _displayName = State(initialValue: config.displayName)
            _host = State(initialValue: config.host)
            _port = State(initialValue: config.port)
            _username = State(initialValue: config.username)
            _authMethod = State(initialValue: config.authMethod)
            _keyPath = State(initialValue: config.keyPath ?? "")
            _remotePath = State(initialValue: config.remotePath)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Display Name", text: $displayName)
                    TextField("Host", text: $host)
                    TextField("Port", value: $port, format: .number)
                    TextField("Username", text: $username)
                }

                Section("Remote") {
                    TextField("Remote Path", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("Password").tag(ConnectionConfig.AuthMethod.password)
                        Text("SSH Key").tag(ConnectionConfig.AuthMethod.sshKey)
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .password {
                        SecureField("Password", text: $password)
                    } else {
                        HStack {
                            TextField("Key File", text: $keyPath)
                            Button("Browse…") { pickKeyFile() }
                        }
                    }
                }

                Section {
                    HStack {
                        Button("Test Connection") { testConnection() }
                            .disabled(isTesting || host.isEmpty || username.isEmpty)
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.isEmpty || host.isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 380)
    }

    // MARK: - Actions

    private func save() {
        var config = ConnectionConfig(
            displayName: displayName,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            keyPath: authMethod == .sshKey ? keyPath : nil,
            remotePath: remotePath.isEmpty ? "/" : remotePath
        )
        if case .edit(let existing) = mode {
            config.id = existing.id
        }

        if authMethod == .password && !password.isEmpty {
            KeychainHelper.save(password: password, forAccount: config.id.uuidString)
        }

        onSave(config)
        dismiss()
    }

    private func pickKeyFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let config = ConnectionConfig(
            displayName: displayName.isEmpty ? host : displayName,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            keyPath: authMethod == .sshKey ? keyPath : nil,
            remotePath: remotePath.isEmpty ? "/" : remotePath
        )

        // Save password temporarily for the test if provided
        if authMethod == .password && !password.isEmpty {
            KeychainHelper.save(password: password, forAccount: config.id.uuidString)
        }

        Task {
            let (success, message) = await store.testConnection(config)
            isTesting = false
            testResult = success ? "✓ Success: \(message)" : message

            // Clean up temp keychain entry if this was a new connection
            if case .add = mode {
                KeychainHelper.delete(account: config.id.uuidString)
            }
        }
    }
}
