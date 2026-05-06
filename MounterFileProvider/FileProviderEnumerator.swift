import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let path: String
    private let connection: SFTPConnection
    private let password: String?
    private let remotePath: String

    init(path: String, connection: SFTPConnection, password: String? = nil, remotePath: String = "/") {
        self.path = path
        self.connection = connection
        self.password = password
        self.remotePath = remotePath
    }

    func invalidate() {
        // No-op; no long-running work to cancel.
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                try await connection.ensureConnected(password: password)
                let files = try await connection.listDirectory(path)
                let items = files.map { FileProviderItem(file: $0, remotePath: self.remotePath) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: currentAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentAnchor)
    }

    private var currentAnchor: NSFileProviderSyncAnchor {
        let data = Data("\(Date().timeIntervalSince1970)".utf8)
        return NSFileProviderSyncAnchor(data)
    }
}
