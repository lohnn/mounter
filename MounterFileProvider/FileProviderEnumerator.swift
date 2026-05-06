import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let path: String
    private let connection: SFTPConnection

    init(path: String, connection: SFTPConnection) {
        self.path = path
        self.connection = connection
    }

    func invalidate() {
        // No-op; no long-running work to cancel.
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let files = try await connection.listDirectory(path)
                let items = files.map { FileProviderItem(file: $0) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // For now, report no incremental changes — the system will fall back to full enumeration.
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
