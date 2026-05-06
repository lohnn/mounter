import Foundation

/// Represents a remote file or directory entry.
public struct SFTPFile: Sendable, Equatable {
    public let name: String
    public let path: String
    public let size: UInt64
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let permissions: String

    public init(name: String, path: String, size: UInt64, isDirectory: Bool, modificationDate: Date?, permissions: String) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.permissions = permissions
    }

    /// Parse a single line of `ls -la` output into an SFTPFile.
    /// Expected format: `drwxr-xr-x    3 user group    4096 Jan  5 12:34 dirname`
    public static func parse(line: String, parentPath: String) -> SFTPFile? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        // ls -la fields: permissions, links, owner, group, size, month, day, time/year, name
        let components = line.split(maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 9 else { return nil }

        let permissions = components[0]
        guard permissions.count >= 10 else { return nil }

        let isDirectory = permissions.hasPrefix("d")
        let size = UInt64(components[4]) ?? 0
        let name = components[8]

        // Skip . and ..
        guard name != "." && name != ".." else { return nil }

        let month = components[5]
        let day = components[6]
        let timeOrYear = components[7]
        let modificationDate = parseDate(month: month, day: day, timeOrYear: timeOrYear)

        let path = parentPath.hasSuffix("/")
            ? parentPath + name
            : parentPath + "/" + name

        return SFTPFile(
            name: name,
            path: path,
            size: size,
            isDirectory: isDirectory,
            modificationDate: modificationDate,
            permissions: permissions
        )
    }

    private static func parseDate(month: String, day: String, timeOrYear: String) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        let months = ["Jan":1,"Feb":2,"Mar":3,"Apr":4,"May":5,"Jun":6,
                      "Jul":7,"Aug":8,"Sep":9,"Oct":10,"Nov":11,"Dec":12]
        guard let m = months[month], let d = Int(day) else { return nil }

        var comps = DateComponents()
        comps.month = m
        comps.day = d

        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            comps.year = currentYear
            comps.hour = Int(parts[0]) ?? 0
            comps.minute = Int(parts[1]) ?? 0
        } else {
            comps.year = Int(timeOrYear) ?? currentYear
        }

        return calendar.date(from: comps)
    }
}
