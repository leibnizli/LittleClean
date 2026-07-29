import Foundation

nonisolated struct Cleaner: Sendable {
    private let scanner: FileSystemScanner

    init(scanner: FileSystemScanner = FileSystemScanner()) {
        self.scanner = scanner
    }

    // Delete the supplied items and synchronously remeasure affected leaves and parent totals.
    func clean(_ items: [CategoryItem], in snapshot: [CategoryItem]) -> [CategoryItem] {
        for item in items {
            cleanItem(item)
        }
        return rebuildRemeasuringCleanedLeaves(
            in: snapshot,
            cleanedIDs: Set(items.map { $0.id })
        )
    }

    private func cleanItem(_ item: CategoryItem) {
        switch item.rule.cleanType {
        case .none:
            break
        case .deleteDirectory:
            let expandedPath = NSString(string: item.pathDescription).expandingTildeInPath
            let fileManager = FileManager.default
            if let contents = try? fileManager.contentsOfDirectory(atPath: expandedPath) {
                for file in contents {
                    let fullPath = (expandedPath as NSString).appendingPathComponent(file)
                    try? fileManager.removeItem(atPath: fullPath)
                }
            }
        case .deleteDirectoryTree:
            let treePath = NSString(string: item.pathDescription).expandingTildeInPath
            try? FileManager.default.removeItem(atPath: treePath)
        case .deletePaths(let paths):
            let fileManager = FileManager.default
            for path in paths {
                try? fileManager.removeItem(atPath: path)
            }
        case .runCommand(let executable, let args):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func rebuildRemeasuringCleanedLeaves(
        in items: [CategoryItem],
        cleanedIDs: Set<UUID>
    ) -> [CategoryItem] {
        items.map { item in
            if let children = item.children, !children.isEmpty {
                let newChildren = rebuildRemeasuringCleanedLeaves(in: children, cleanedIDs: cleanedIDs)
                var rebuilt = item
                rebuilt.children = newChildren
                let total = newChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
                rebuilt.sizeBytes = total
                rebuilt.sizeString = total > 0 ? formatBytes(total) : ""
                return rebuilt
            } else if cleanedIDs.contains(item.id) {
                let expanded = NSString(string: item.pathDescription).expandingTildeInPath
                var isDirectory: ObjCBool = false
                let newSize: Int64 = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
                    ? scanner.calculateDirectorySize(at: expanded, isDirectory: isDirectory.boolValue)
                    : 0
                var rebuilt = item
                rebuilt.sizeBytes = newSize
                rebuilt.sizeString = newSize > 0 ? formatBytes(newSize) : ""
                return rebuilt
            } else {
                return item
            }
        }
    }
}
