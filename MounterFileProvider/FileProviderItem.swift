import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {

    private let file: SFTPFile
    private let isRoot: Bool

    init(file: SFTPFile) {
        self.file = file
        self.isRoot = false
    }

    private override init() {
        self.file = SFTPFile(name: "/", path: "/", size: 0, isDirectory: true, modificationDate: nil, permissions: "drwxr-xr-x")
        self.isRoot = true
    }

    static let root = FileProviderItem()

    // MARK: - NSFileProviderItem

    var itemIdentifier: NSFileProviderItemIdentifier {
        if isRoot {
            return .rootContainer
        }
        return Self.identifier(forPath: file.path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if isRoot {
            return .rootContainer
        }
        let parent = (file.path as NSString).deletingLastPathComponent
        if parent == "/" || parent.isEmpty {
            return .rootContainer
        }
        return Self.identifier(forPath: parent)
    }

    var capabilities: NSFileProviderItemCapabilities {
        if file.isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
    }

    var filename: String {
        file.name
    }

    var contentType: UTType {
        if file.isDirectory {
            return .folder
        }
        return UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? {
        file.isDirectory ? nil : NSNumber(value: file.size)
    }

    var contentModificationDate: Date? {
        file.modificationDate
    }

    var creationDate: Date? {
        file.modificationDate
    }

    // MARK: - Identifier Helpers

    static func identifier(forPath path: String) -> NSFileProviderItemIdentifier {
        let encoded = Data(path.utf8).base64EncodedString()
        return NSFileProviderItemIdentifier(encoded)
    }

    static func path(fromIdentifier identifier: NSFileProviderItemIdentifier) -> String? {
        guard let data = Data(base64Encoded: identifier.rawValue),
              let path = String(data: data, encoding: .utf8) else {
            return nil
        }
        return path
    }
}
