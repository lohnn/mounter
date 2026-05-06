import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private var connection: SFTPConnection?
    private var config: ConnectionConfig?

    private static let appGroupIdentifier = "group.se.lohnn.mounter"
    private static let configsFileName = "connections.json"

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        loadConfig()
    }

    // MARK: - Configuration

    private func loadConfig() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return }

        let fileURL = containerURL.appendingPathComponent(Self.configsFileName)
        guard let data = try? Data(contentsOf: fileURL),
              let configs = try? JSONDecoder().decode([ConnectionConfig].self, from: data) else {
            return
        }

        // Domain identifier matches the ConnectionConfig UUID string.
        config = configs.first { $0.id.uuidString == domain.identifier.rawValue }
    }

    private func getConnection() async throws -> SFTPConnection {
        if let existing = connection {
            return existing
        }
        guard let config else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let conn = SFTPConnection(config: config)
        try await conn.connect()
        self.connection = conn
        return conn
    }

    // MARK: - NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let item: NSFileProviderItem
                if identifier == .rootContainer {
                    item = FileProviderItem.root
                } else {
                    guard let path = FileProviderItem.path(fromIdentifier: identifier) else {
                        throw NSFileProviderError(.noSuchItem)
                    }
                    let conn = try await getConnection()
                    let file = try await conn.stat(path)
                    item = FileProviderItem(file: file)
                }
                progress.completedUnitCount = 1
                completionHandler(item, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard let remotePath = FileProviderItem.path(fromIdentifier: itemIdentifier) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let conn = try await getConnection()
                let file = try await conn.stat(remotePath)

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let localURL = tempDir.appendingPathComponent(file.name)

                try await conn.readFile(remotePath, to: localURL.path)

                let item = FileProviderItem(file: file)
                progress.completedUnitCount = 1
                completionHandler(localURL, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let conn = try await getConnection()

                let parentPath: String
                if itemTemplate.parentItemIdentifier == .rootContainer {
                    parentPath = "/"
                } else {
                    guard let p = FileProviderItem.path(fromIdentifier: itemTemplate.parentItemIdentifier) else {
                        throw NSFileProviderError(.noSuchItem)
                    }
                    parentPath = p
                }

                let remotePath = (parentPath as NSString).appendingPathComponent(itemTemplate.filename)

                if itemTemplate.contentType == .folder {
                    try await conn.mkdir(remotePath)
                } else if let localURL = url {
                    try await conn.writeFile(from: localURL.path, to: remotePath)
                }

                let file = try await conn.stat(remotePath)
                let item = FileProviderItem(file: file)
                progress.completedUnitCount = 1
                completionHandler(item, [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard var remotePath = FileProviderItem.path(fromIdentifier: item.itemIdentifier) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let conn = try await getConnection()

                // Handle rename / move
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParent: String
                    if item.parentItemIdentifier == .rootContainer {
                        newParent = "/"
                    } else {
                        guard let p = FileProviderItem.path(fromIdentifier: item.parentItemIdentifier) else {
                            throw NSFileProviderError(.noSuchItem)
                        }
                        newParent = p
                    }
                    let newPath = (newParent as NSString).appendingPathComponent(item.filename)
                    if newPath != remotePath {
                        try await conn.rename(from: remotePath, to: newPath)
                        remotePath = newPath
                    }
                }

                // Handle content update
                if changedFields.contains(.contents), let localURL = newContents {
                    try await conn.writeFile(from: localURL.path, to: remotePath)
                }

                let file = try await conn.stat(remotePath)
                let updatedItem = FileProviderItem(file: file)
                progress.completedUnitCount = 1
                completionHandler(updatedItem, [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard let remotePath = FileProviderItem.path(fromIdentifier: identifier) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let conn = try await getConnection()
                try await conn.remove(remotePath)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
        return progress
    }

    func invalidate() {
        Task {
            await connection?.disconnect()
        }
        connection = nil
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let path: String
        if containerItemIdentifier == .rootContainer {
            path = "/"
        } else if containerItemIdentifier == .workingSet {
            // Working set — return root enumerator for simplicity
            path = "/"
        } else {
            guard let p = FileProviderItem.path(fromIdentifier: containerItemIdentifier) else {
                throw NSFileProviderError(.noSuchItem)
            }
            path = p
        }

        guard let conn = connection else {
            // Lazily connect if needed — create connection synchronously for enumerator,
            // actual operations are async inside the enumerator.
            guard let config else {
                throw NSFileProviderError(.notAuthenticated)
            }
            let conn = SFTPConnection(config: config)
            self.connection = conn
            // Kick off connection asynchronously; enumerator will wait on first use.
            Task { try await conn.connect() }
            return FileProviderEnumerator(path: path, connection: conn)
        }

        return FileProviderEnumerator(path: path, connection: conn)
    }
}
