import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ConnectionStore
    @State private var selection: ConnectionConfig.ID?
    @State private var showingAddForm = false
    @State private var showingEditForm = false
    @State private var showingLog = false
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        VSplitView {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }

            if showingLog {
                LogView()
            }
        }
        .sheet(isPresented: $showingAddForm) {
            ConnectionFormView(mode: .add) { config in
                store.add(config)
            }
        }
        .sheet(isPresented: $showingEditForm) {
            if let id = selection, let config = store.connections.first(where: { $0.id == id }) {
                ConnectionFormView(mode: .edit(config)) { updated in
                    store.update(updated)
                    if updated.authMethod == .password {
                        // Password is saved inside the form's save action
                    }
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(store.connections) { config in
                HStack {
                    statusIndicator(for: config.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.displayName)
                            .font(.headline)
                        Text("\(config.username)@\(config.host):\(config.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(config.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Mounter")
        .toolbar {
            ToolbarItemGroup {
                Button(action: { showingAddForm = true }) {
                    Label("Add", systemImage: "plus")
                }
                Button(action: removeSelected) {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection == nil)
                Button(action: { showingLog.toggle() }) {
                    Label("Log", systemImage: "text.alignleft")
                }
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let id = selection, let config = store.connections.first(where: { $0.id == id }) {
                connectionDetail(config)
            } else {
                Text("Select a connection")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectionDetail(_ config: ConnectionConfig) -> some View {
        VStack(spacing: 20) {
            Text(config.displayName)
                .font(.title)

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Host:").fontWeight(.medium)
                        Text(config.host)
                    }
                    GridRow {
                        Text("Port:").fontWeight(.medium)
                        Text("\(config.port)")
                    }
                    GridRow {
                        Text("User:").fontWeight(.medium)
                        Text(config.username)
                    }
                    GridRow {
                        Text("Auth:").fontWeight(.medium)
                        Text(config.authMethod == .password ? "Password" : "SSH Key")
                    }
                }
                .padding(8)
            }

            HStack(spacing: 12) {
                let state = store.state(for: config.id)
                if state == .connected {
                    Button("Unmount") { store.unmount(config) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Mount") { store.mount(config) }
                        .buttonStyle(.borderedProminent)
                        .disabled(state == .connecting)
                }
                Button("Test") { testConnection(config) }
                    .disabled(isTesting)
                Button("Edit") { showingEditForm = true }
            }

            if isTesting {
                ProgressView("Testing connection…")
                    .controlSize(.small)
            }
            if let result = testResult {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func statusIndicator(for id: ConnectionConfig.ID) -> some View {
        Circle()
            .fill(statusColor(for: id))
            .frame(width: 8, height: 8)
    }

    private func statusColor(for id: ConnectionConfig.ID) -> Color {
        switch store.state(for: id) {
        case .disconnected: return .gray
        case .connecting:   return .orange
        case .connected:    return .green
        case .error:        return .red
        }
    }

    private func removeSelected() {
        guard let id = selection,
              let config = store.connections.first(where: { $0.id == id }) else { return }
        store.remove(config)
        selection = nil
    }

    private func testConnection(_ config: ConnectionConfig) {
        isTesting = true
        testResult = nil
        Task {
            let (success, message) = await store.testConnection(config)
            isTesting = false
            testResult = success ? "✓ \(message)" : message
        }
    }
}
