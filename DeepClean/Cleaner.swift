import AppKit
import Foundation
import Security

nonisolated struct CleanFailure: Sendable {
    let path: String
    let domain: String
    let code: Int
    let reason: String
}

nonisolated struct CleanResult: Sendable {
    let categories: [CategoryItem]
    let failures: [CleanFailure]
}

nonisolated struct Cleaner: Sendable {
    private let scanner: FileSystemScanner

    init(scanner: FileSystemScanner = FileSystemScanner()) {
        self.scanner = scanner
    }

    // Delete the supplied items and synchronously remeasure affected leaves and parent totals.
    func clean(_ items: [CategoryItem], in snapshot: [CategoryItem]) -> CleanResult {
        var failures: [CleanFailure] = []
        for item in items {
            failures.append(contentsOf: cleanItem(item))
        }
        return CleanResult(
            categories: rebuildRemeasuringCleanedLeaves(
                in: snapshot,
                cleanedIDs: Set(items.map { $0.id })
            ),
            failures: failures
        )
    }

    private func cleanItem(_ item: CategoryItem) -> [CleanFailure] {
        var failures: [CleanFailure] = []

        func recordFailure(_ error: Error, path: String) {
            let nsError = error as NSError
            failures.append(CleanFailure(
                path: path,
                domain: nsError.domain,
                code: nsError.code,
                reason: nsError.localizedDescription
            ))
        }

        switch item.rule.cleanType {
        case .none:
            break
        case .deleteDirectory:
            let expandedPath = NSString(string: item.pathDescription).expandingTildeInPath
            let fileManager = FileManager.default
            if let contents = try? fileManager.contentsOfDirectory(atPath: expandedPath) {
                for file in contents {
                    let fullPath = (expandedPath as NSString).appendingPathComponent(file)
                    do {
                        try fileManager.removeItem(atPath: fullPath)
                    } catch {
                        recordFailure(error, path: fullPath)
                    }
                }
            }
        case .deleteDirectoryTree:
            let treePath = NSString(string: item.pathDescription).expandingTildeInPath
            do {
                try FileManager.default.removeItem(atPath: treePath)
            } catch {
                recordFailure(error, path: treePath)
            }
        case .deletePaths(let paths):
            let fileManager = FileManager.default
            let appPaths = paths.filter {
                URL(fileURLWithPath: $0).pathExtension.lowercased() == "app"
            }
            if let failure = applicationPreflightFailure(for: appPaths) {
                return [failure]
            }

            let orderedPaths = appPaths + paths.filter { !appPaths.contains($0) }
            for path in orderedPaths {
                guard fileManager.fileExists(atPath: path) else { continue }
                do {
                    try fileManager.removeItem(atPath: path)
                } catch {
                    recordFailure(error, path: path)
                    // Do not remove user data when the application bundle itself could
                    // not be removed. This avoids resetting an app that remains installed.
                    if appPaths.contains(path) {
                        return failures
                    }
                }
            }
        case .trashPaths(let paths):
            let fileManager = FileManager.default
            let appPaths = paths.filter {
                URL(fileURLWithPath: $0).pathExtension.lowercased() == "app"
            }
            if let failure = applicationPreflightFailure(for: appPaths) {
                return [failure]
            }

            let orderedPaths = appPaths + paths.filter { !appPaths.contains($0) }
            for path in orderedPaths {
                guard fileManager.fileExists(atPath: path) else { continue }
                do {
                    try fileManager.trashItem(
                        at: URL(fileURLWithPath: path),
                        resultingItemURL: nil
                    )
                } catch {
                    recordFailure(error, path: path)
                    // Keep the installed app and its data together when the primary
                    // bundle could not be moved to Trash.
                    if appPaths.contains(path) {
                        return failures
                    }
                }
            }
        case .runCommand(let executable, let args):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    failures.append(CleanFailure(
                        path: item.pathDescription,
                        domain: "Process",
                        code: Int(process.terminationStatus),
                        reason: "\(executable) exited with status \(process.terminationStatus)"
                    ))
                }
            } catch {
                recordFailure(error, path: item.pathDescription)
            }
        }

        return failures
    }

    private func applicationPreflightFailure(for appPaths: [String]) -> CleanFailure? {
        for appPath in appPaths {
            let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
            let resolvedURL = appURL.resolvingSymlinksInPath().standardizedFileURL
            let resolvedPath = resolvedURL.path
            let resourceValues = try? resolvedURL.resourceValues(forKeys: [
                .isSystemImmutableKey,
                .volumeIsReadOnlyKey
            ])
            let isCurrentApp = appURL.path == Bundle.main.bundleURL.standardizedFileURL.path
            let isSystemApp = resolvedPath.hasPrefix("/System/")
                || resolvedPath.hasPrefix("/System/Cryptexes/")
                || resolvedPath.hasPrefix("/Library/Apple/")
                || resourceValues?.isSystemImmutable == true
                || resourceValues?.volumeIsReadOnly == true
                || isApplePlatformSystemApplication(at: resolvedURL)
            if isCurrentApp || isSystemApp {
                return CleanFailure(
                    path: appPath,
                    domain: "DeepClean",
                    code: 1,
                    reason: String(
                        localized: "DeepClean refuses to remove itself or a protected system application."
                    )
                )
            }

            if let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier,
               !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
               ).isEmpty {
                return CleanFailure(
                    path: appPath,
                    domain: "DeepClean",
                    code: 2,
                    reason: String(
                        localized: "The application is running. Quit it completely, then try again."
                    )
                )
            }
        }
        return nil
    }

    private func isApplePlatformSystemApplication(at appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return false
        }

        var appleAnchor: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple" as CFString,
            SecCSFlags(rawValue: 0),
            &appleAnchor
        ) == errSecSuccess,
              let appleAnchor,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                appleAnchor
              ) == errSecSuccess else {
            return false
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let platform = info[kSecCodeInfoPlatformIdentifier as String] as? NSNumber else {
            return false
        }
        return platform.uint32Value != 0
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
