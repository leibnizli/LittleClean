import AppKit
import SwiftUI

private nonisolated func normalizeAppIdentifier(_ str: String) -> String {
    str.lowercased()
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ".", with: "")
}

// A snapshot of what is currently installed, used to tell "still in use" from "leftover".
// Building it walks every application bundle on the system and reads its plists, so it is
// cached across a scan pass instead of being rebuilt by each of the four scans that ask.
private nonisolated final class InstalledAppIndex: @unchecked Sendable {
    static let shared = InstalledAppIndex()

    // Long enough for one pass (categories + details) to share a snapshot, short enough
    // that installing or deleting an app is reflected by the next scan.
    private static let cacheLifetime: TimeInterval = 15
    private static let maxSearchDepth = 4

    // Walked recursively: apps are routinely filed into subfolders, Setapp installs into
    // /Applications/Setapp, and CoreServices nests system apps several levels down.
    private static let searchRoots: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
    ]

    private let lock = NSLock()
    private var cachedIdentifiers: Set<String>?
    private var cachedAt = Date.distantPast
    private var bundleIdentifierResults: [String: Bool] = [:]

    func installedIdentifiers() -> Set<String> {
        lock.lock()
        if let cachedIdentifiers, Date().timeIntervalSince(cachedAt) < Self.cacheLifetime {
            lock.unlock()
            return cachedIdentifiers
        }
        lock.unlock()

        let identifiers = Self.buildIdentifiers()

        lock.lock()
        cachedIdentifiers = identifiers
        cachedAt = Date()
        lock.unlock()

        return identifiers
    }

    // LaunchServices knows where every registered bundle id actually lives, including
    // apps on other volumes and helpers or extensions nested inside another bundle --
    // places the directory walk deliberately never descends into.
    func isRegisteredBundleIdentifier(_ candidate: String) -> Bool {
        guard candidate.contains("."),
              !candidate.hasPrefix("."),
              !candidate.hasSuffix("."),
              !candidate.contains(" "),
              !candidate.contains("/") else {
            return false
        }

        lock.lock()
        if let cached = bundleIdentifierResults[candidate] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.resolveOwningApp(candidate)

        lock.lock()
        bundleIdentifierResults[candidate] = resolved
        lock.unlock()

        return resolved
    }

    private static func resolveOwningApp(_ candidate: String) -> Bool {
        var components = candidate.split(separator: ".").map(String.init)

        // Group containers are prefixed with the developer's 10-character team id.
        if let first = components.first,
           first.count == 10,
           first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            components.removeFirst()
        }

        // Extension and helper identifiers extend the owning app's id with extra
        // components ("com.foo.Bar.ShareExtension"), so walk back toward the app.
        while components.count >= 2 {
            if isRegistered(components.joined(separator: ".")) {
                return true
            }
            components.removeLast()
        }

        return false
    }

    private static func isRegistered(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func buildIdentifiers() -> Set<String> {
        var identifiers = Set<String>()
        let fileManager = FileManager.default

        for root in searchRoots {
            for bundleURL in appBundles(in: root) {
                // 1. Finder display name (e.g. "WeChat DevTools")
                let finderName = fileManager.displayName(atPath: bundleURL.path)
                insert((finderName as NSString).deletingPathExtension, into: &identifiers)

                // 2. On-disk bundle name (e.g. "wechatwebdevtools")
                insert(bundleURL.deletingPathExtension().lastPathComponent, into: &identifiers)

                // 3. Info.plist
                let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: infoPlistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                    if let bundleID = plist["CFBundleIdentifier"] as? String {
                        insert(bundleID, into: &identifiers)
                        insert((bundleID as NSString).pathExtension, into: &identifiers)
                    }
                    insert(plist["CFBundleName"] as? String, into: &identifiers)
                    insert(plist["CFBundleDisplayName"] as? String, into: &identifiers)
                }

                // 4. Localized names (e.g. zh_CN.lproj, zh-Hans.lproj)
                let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources")
                guard let resources = try? fileManager.contentsOfDirectory(atPath: resourcesURL.path) else { continue }
                for resource in resources where resource.hasSuffix(".lproj") {
                    let stringsURL = resourcesURL
                        .appendingPathComponent(resource)
                        .appendingPathComponent("InfoPlist.strings")
                    guard let data = try? Data(contentsOf: stringsURL),
                          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
                        continue
                    }
                    insert(plist["CFBundleDisplayName"], into: &identifiers)
                    insert(plist["CFBundleName"], into: &identifiers)
                }
            }
        }

        return identifiers
    }

    private static func insert(_ value: String?, into identifiers: inout Set<String>) {
        guard let value, !value.isEmpty else { return }
        let lowered = value.lowercased()
        identifiers.insert(lowered)
        identifiers.insert(normalizeAppIdentifier(lowered))
    }

    // Collect every .app under a root, descending through plain folders but never into a
    // bundle's own contents (an .app or .framework holds hundreds of irrelevant files).
    private static func appBundles(in root: String) -> [URL] {
        let fileManager = FileManager.default
        var bundles: [URL] = []
        var pending: [(path: String, depth: Int)] = [(root, 0)]

        while let (path, depth) = pending.popLast() {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let fullPath = (path as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }

                if entry.hasSuffix(".app") {
                    bundles.append(URL(fileURLWithPath: fullPath))
                } else if depth < maxSearchDepth && (entry as NSString).pathExtension.isEmpty {
                    pending.append((fullPath, depth + 1))
                }
            }
        }

        return bundles
    }
}

// Everything macOS itself ships. Since Catalina the OS lives on a sealed, read-only
// volume, so the names that belong to the system are a finite set that can be enumerated
// exactly -- launchd's job registry plus the executables and bundles on that volume --
// instead of approximated with a hand-written deny list. A folder under Application
// Support whose name appears here was created by macOS, not by an app the user installed.
private nonisolated final class SystemComponentIndex: @unchecked Sendable {
    static let shared = SystemComponentIndex()

    // Daemons routinely name their folder after the framework hosting them plus a suffix
    // (CallHistory.framework -> CallHistoryTransactions), so prefixes have to match too.
    // The bound stops short, generic system names from swallowing third-party folders.
    private static let minimumPrefixLength = 8

    // launchd's job definitions are the authoritative registry of every service macOS runs.
    private static let launchdDirectories = [
        "/System/Library/LaunchDaemons",
        "/System/Library/LaunchAgents",
        "/Library/Apple/System/Library/LaunchDaemons",
        "/Library/Apple/System/Library/LaunchAgents"
    ]

    private static let executableDirectories = [
        "/usr/libexec",
        "/usr/sbin",
        "/usr/bin",
        "/System/Library/CoreServices"
    ]

    private static let frameworkDirectories = [
        "/System/Library/PrivateFrameworks",
        "/System/Library/Frameworks"
    ]

    // Where a framework keeps the daemons, XPC services and helper apps it owns.
    private static let frameworkPayloadSubpaths = [
        "Support", "Versions/A/Support",
        "XPCServices", "Versions/A/XPCServices",
        "Helpers", "Versions/A/Helpers",
        "Resources", "Versions/A/Resources"
    ]

    private static let bundleDirectories = [
        "/System/Library/Extensions",
        "/System/Library/ExtensionKit/Extensions",
        "/System/Library/Services",
        "/System/Library/Spotlight",
        "/System/Library/PreferencePanes",
        "/System/Applications",
        "/System/Library/CoreServices/Applications"
    ]

    private static let bundleExtensions: Set<String> = [
        "app", "xpc", "appex", "bundle", "framework", "service", "prefpane", "mdimporter"
    ]

    private let lock = NSLock()
    private var cachedNames: Set<String>?

    func isSystemOwned(_ folder: String) -> Bool {
        let index = systemNames()
        let lower = folder.lowercased()
        if index.contains(lower) || index.contains(normalizeAppIdentifier(folder)) {
            return true
        }

        // Test the folder's own prefixes against the index rather than scanning thousands
        // of entries. Deliberately uses the raw lowercased name: normalizing away the dot
        // in "default.store" would let the unrelated "defaults" tool match it.
        guard lower.count > Self.minimumPrefixLength else { return false }
        let characters = Array(lower)
        for length in Self.minimumPrefixLength..<characters.count
        where index.contains(String(characters[0..<length])) {
            return true
        }
        return false
    }

    // The system volume is sealed and read-only, so this is built once per launch.
    private func systemNames() -> Set<String> {
        lock.lock()
        if let cachedNames {
            lock.unlock()
            return cachedNames
        }
        lock.unlock()

        let built = Self.build()

        lock.lock()
        cachedNames = built
        lock.unlock()

        return built
    }

    private static func build() -> Set<String> {
        var names = Set<String>()
        let fileManager = FileManager.default

        func add(_ value: String?) {
            guard let value else { return }
            let base = (value as NSString).lastPathComponent
            guard !base.isEmpty else { return }
            names.insert(base.lowercased())
            names.insert(normalizeAppIdentifier(base))
        }

        for directory in launchdDirectories {
            guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = (directory as NSString).appendingPathComponent(file)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let job = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    continue
                }
                if let label = job["Label"] as? String {
                    add(label)
                    add(label.split(separator: ".").last.map(String.init))
                }
                add(job["Program"] as? String)
                add((job["ProgramArguments"] as? [String])?.first)
            }
        }

        for directory in executableDirectories {
            var pending: [(path: String, depth: Int)] = [(directory, 0)]
            while let (path, depth) = pending.popLast() {
                guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
                for entry in entries {
                    if bundleExtensions.contains((entry as NSString).pathExtension.lowercased()) {
                        add((entry as NSString).deletingPathExtension)
                        continue
                    }
                    let fullPath = (path as NSString).appendingPathComponent(entry)
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { continue }
                    if isDirectory.boolValue {
                        if depth < 2 { pending.append((fullPath, depth + 1)) }
                    } else {
                        add(entry)
                    }
                }
            }
        }

        for base in frameworkDirectories {
            guard let frameworks = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for framework in frameworks where framework.hasSuffix(".framework") {
                add((framework as NSString).deletingPathExtension)
                let frameworkPath = (base as NSString).appendingPathComponent(framework)
                for subpath in frameworkPayloadSubpaths {
                    let payloadPath = (frameworkPath as NSString).appendingPathComponent(subpath)
                    guard let entries = try? fileManager.contentsOfDirectory(atPath: payloadPath) else { continue }
                    for entry in entries {
                        let fileExtension = (entry as NSString).pathExtension.lowercased()
                        if bundleExtensions.contains(fileExtension) {
                            add((entry as NSString).deletingPathExtension)
                            continue
                        }
                        // Resources also holds ordinary assets; only an extensionless
                        // executable is a daemon whose generic name belongs in the index.
                        guard fileExtension.isEmpty else { continue }
                        let entryPath = (payloadPath as NSString).appendingPathComponent(entry)
                        var isDirectory: ObjCBool = false
                        guard fileManager.fileExists(atPath: entryPath, isDirectory: &isDirectory),
                              !isDirectory.boolValue,
                              fileManager.isExecutableFile(atPath: entryPath) else {
                            continue
                        }
                        add(entry)
                    }
                }
            }
        }

        for base in bundleDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for entry in entries {
                add((entry as NSString).deletingPathExtension)
            }
        }

        return names
    }
}

// Every command-line tool and package the user has installed. Application Support folders
// are created by CLI tools, SDKs and language runtimes at least as often as by .app
// bundles, and none of those are discoverable by looking at /Applications.
private nonisolated final class InstalledToolIndex: @unchecked Sendable {
    static let shared = InstalledToolIndex()

    private static let cacheLifetime: TimeInterval = 15

    // Package managers and language runtimes that install into a fixed location.
    private static let fixedDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/opt/local/bin", "/opt/local/sbin",           // MacPorts
        "/sw/bin", "/sw/sbin",                         // Fink
        "/nix/var/nix/profiles/default/bin",
        "~/.nix-profile/bin",
        "~/bin", "~/.local/bin",
        "~/.cargo/bin",                                // Rust
        "~/go/bin",                                    // Go
        "~/.bun/bin", "~/.deno/bin",
        "~/.volta/bin",
        "~/.yarn/bin", "~/.config/yarn/global/node_modules/.bin",
        "~/.npm-global/bin", "~/.npm-packages/bin",
        "~/.pyenv/shims", "~/.pyenv/bin",
        "~/.rbenv/shims", "~/.nodenv/shims",
        "~/.asdf/shims", "~/.asdf/bin",
        "~/.fnm/aliases/default/bin",
        "~/.dotnet/tools",
        "~/.krew/bin",                                 // kubectl plugins
        "~/.rye/shims", "~/.pixi/bin", "~/.poetry/bin",
        "~/.composer/vendor/bin", "~/.config/composer/vendor/bin",
        "~/anaconda3/bin", "~/miniconda3/bin", "~/miniforge3/bin", "~/mambaforge/bin",
        "/opt/anaconda3/bin", "/opt/miniconda3/bin",
        "/opt/homebrew/Caskroom/miniconda/base/bin",
        "/Library/Apple/usr/bin",
        "~/Library/pnpm",
        "~/flutter/bin",
        "~/Library/Android/sdk/platform-tools",
        "~/Library/Android/sdk/cmdline-tools/latest/bin",
        "~/Library/Android/sdk/emulator"
    ]

    // Version managers keep one toolchain per directory, so their bin folders can only be
    // found by enumerating which versions are actually installed.
    private static let versionedRoots: [(root: String, suffix: String)] = [
        ("~/.nvm/versions/node", "bin"),
        ("~/.fnm/node-versions", "installation/bin"),
        ("~/Library/Application Support/fnm/node-versions", "installation/bin"),
        ("~/.volta/tools/image/node", "bin"),
        ("~/.sdkman/candidates", "current/bin"),
        ("~/Library/Python", "bin"),
        ("~/.gem/ruby", "bin"),
        ("~/.rbenv/versions", "bin"),
        ("~/.pyenv/versions", "bin"),
        ("~/.nodenv/versions", "bin"),
        ("/opt/homebrew/opt", "bin"),                  // keg-only formulae
        ("/usr/local/opt", "bin")
    ]

    // Package names, which routinely differ from the command they install.
    private static let packageRoots = [
        "/opt/homebrew/Cellar", "/usr/local/Cellar",
        "/opt/homebrew/Caskroom", "/usr/local/Caskroom",
        "/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules",
        "~/.npm-global/lib/node_modules",
        "~/.bun/install/global/node_modules",
        "~/.config/yarn/global/node_modules",
        "~/.local/share/pnpm/global/5/node_modules",
        "~/.local/pipx/venvs"
    ]

    private let lock = NSLock()
    private var cachedNames: Set<String>?
    private var cachedAt = Date.distantPast

    func isInstalledTool(_ name: String) -> Bool {
        let index = toolNames()
        if index.contains(name.lowercased()) || index.contains(normalizeAppIdentifier(name)) {
            return true
        }

        // Reverse-domain folders are named for the vendor, not the command: the folder
        // "com.openai.codex" is written by a CLI simply called "codex".
        guard let lastComponent = name.split(separator: ".").last, lastComponent.count >= 3 else {
            return false
        }
        let command = String(lastComponent)
        return index.contains(command.lowercased()) || index.contains(normalizeAppIdentifier(command))
    }

    private func toolNames() -> Set<String> {
        lock.lock()
        if let cachedNames, Date().timeIntervalSince(cachedAt) < Self.cacheLifetime {
            lock.unlock()
            return cachedNames
        }
        lock.unlock()

        let built = Self.build()

        lock.lock()
        cachedNames = built
        cachedAt = Date()
        lock.unlock()

        return built
    }

    private static func build() -> Set<String> {
        var names = Set<String>()
        let fileManager = FileManager.default

        func add(_ value: String) {
            guard !value.isEmpty, !value.hasPrefix(".") else { return }
            names.insert(value.lowercased())
            names.insert(normalizeAppIdentifier(value))
        }

        for directory in searchDirectories() {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries {
                add(entry)
            }
        }

        for root in packageRoots {
            let expanded = NSString(string: root).expandingTildeInPath
            guard let entries = try? fileManager.contentsOfDirectory(atPath: expanded) else { continue }
            for entry in entries {
                // npm scopes hold the real package names one level down.
                guard entry.hasPrefix("@") else {
                    add(entry)
                    continue
                }
                let scopePath = (expanded as NSString).appendingPathComponent(entry)
                for scoped in (try? fileManager.contentsOfDirectory(atPath: scopePath)) ?? [] {
                    add(scoped)
                }
            }
        }

        return names
    }

    private static func searchDirectories() -> [String] {
        // The only complete source. Tools get installed wherever their owner decided
        // (/pkg/env/global/bin, ~/flutter/bin, inside an app bundle), so no fixed list can
        // be exhaustive, and a GUI process inherits a minimal PATH that never reflects the
        // user's shell configuration. The lists below are the fallback for when the shell
        // cannot be consulted.
        var directories = loginShellPath()

        // path_helper assembles the system PATH from these files. Unlike the process
        // environment they are readable here, and third-party installers register their
        // own directories in paths.d.
        directories += pathEntries(inFile: "/etc/paths")
        let pathsDirectory = "/etc/paths.d"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: pathsDirectory)) ?? [] {
            directories += pathEntries(inFile: (pathsDirectory as NSString).appendingPathComponent(file))
        }
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            directories += environmentPath.split(separator: ":").map(String.init)
        }

        directories += fixedDirectories.map { NSString(string: $0).expandingTildeInPath }

        for (root, suffix) in versionedRoots {
            let expandedRoot = NSString(string: root).expandingTildeInPath
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: expandedRoot) else { continue }
            for version in versions where !version.hasPrefix(".") {
                directories.append(
                    (expandedRoot as NSString)
                        .appendingPathComponent(version)
                        .appending("/\(suffix)")
                )
            }
        }

        return Array(Set(directories))
    }

    private static func pathEntries(inFile path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // Run the user's shell as a login + interactive shell so it sources the same profile
    // files a terminal would, then ask it for the resulting PATH.
    private static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        // A profile that prompts for input or hangs must not stall the scan.
        var output = Data()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return []
        }
        process.waitUntilExit()

        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.split(separator: ":").map(String.init) } ?? []
    }
}

nonisolated struct CategoryScanResult: Sendable {
    let categories: [CategoryItem]
    let containerAccessDenied: Bool
}

nonisolated struct DetailScanResult: Sendable {
    let items: [CategoryItem]
    let containerAccessDenied: Bool
}

nonisolated struct FileSystemScanner: Sendable {
    // Scan configured paths synchronously. Callers are responsible for running this off the main thread.
    func scanCategories(mode: ScanMode) -> CategoryScanResult {
        var foundCategories: [CategoryItem] = []
        var containerAccessDenied = false
        let fileManager = FileManager.default

        for rule in CleanConfig.defaultRules where rule.scanMode == mode {
            let expandedPath = NSString(string: rule.pathDescription).expandingTildeInPath
            var isDirectory: ObjCBool = false

            if rule.isDynamicSimulatorRule {
                foundCategories.append(contentsOf: scanSimulatorVersions(basePath: rule.pathDescription))
            } else if rule.isDynamicUnavailableSimulatorRule {
                foundCategories.append(contentsOf: scanUnavailableSimulators(basePath: rule.pathDescription))
            } else if rule.isDynamicLeftoversRule {
                foundCategories.append(contentsOf: scanAppLeftovers(basePath: rule.pathDescription))
            } else if rule.isDynamicContainerLeftoversRule {
                let result = scanContainerLeftovers(basePath: rule.pathDescription)
                foundCategories.append(contentsOf: result.items)
                containerAccessDenied = result.accessDenied
            } else if rule.isDynamicHomeCleanupRule {
                let allChildren = scanHomeCaches(basePath: rule.pathDescription)

                if !allChildren.isEmpty {
                    let totalBytes = allChildren.reduce(0) { $0 + $1.sizeBytes }
                    var parent = CategoryItem(
                        name: rule.name,
                        pathDescription: rule.pathDescription,
                        iconName: rule.iconName,
                        iconColor: rule.iconColor,
                        sizeBytes: totalBytes,
                        sizeString: formatBytes(totalBytes),
                        rule: rule,
                        children: allChildren
                    )
                    parent.displayPath = "~ (Caches)"
                    foundCategories.append(parent)
                }
            } else if fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
                let totalBytes = calculateDirectorySize(at: expandedPath, isDirectory: isDirectory.boolValue)
                let item = CategoryItem(
                    name: rule.name,
                    pathDescription: rule.pathDescription,
                    iconName: rule.iconName,
                    iconColor: rule.iconColor,
                    sizeBytes: totalBytes,
                    sizeString: formatBytes(totalBytes),
                    rule: rule
                )
                foundCategories.append(item)
            }
        }

        let categories = mode == .deepAnalysis
            ? foundCategories.map(makeReadOnly)
            : foundCategories
        return CategoryScanResult(
            categories: categories,
            containerAccessDenied: containerAccessDenied
        )
    }

    private func makeReadOnly(_ item: CategoryItem) -> CategoryItem {
        var readOnlyRule = item.rule
        readOnlyRule.cleanType = .none
        return CategoryItem(
            name: item.name,
            pathDescription: item.pathDescription,
            iconName: item.iconName,
            iconColor: item.iconColor,
            sizeBytes: item.sizeBytes,
            sizeString: item.sizeString,
            rule: readOnlyRule,
            children: item.children?.map(makeReadOnly),
            isSelected: false,
            isDisplayOnly: true,
            finderPath: item.finderPath ?? item.pathDescription,
            displayPath: item.displayPath,
            description: item.description
        )
    }

    // Build read-only informational sections synchronously on a background queue.
    func scanDetails() -> DetailScanResult {
        let toolsItem = scanInstalledTools()
        let homeItem = scanHomeDirectory()
        let appDataItem = scanInstalledAppData(basePath: "~/Library/Application Support")
        let containerResult = scanInstalledAppContainers()
        let items = ([toolsItem] + [homeItem, appDataItem, containerResult.item].compactMap { $0 }).filter {
            guard let children = $0.children else { return false }
            return !children.isEmpty
        }
        return DetailScanResult(
            items: items,
            containerAccessDenied: containerResult.accessDenied
        )
    }

    // Dynamically scan simulator devices by OS version
    private func scanSimulatorVersions(basePath: String) -> [CategoryItem] {
        let expandedPath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default
        guard let deviceFolders = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return []
        }

        var versionGroups: [String: (paths: [String], bytes: Int64, count: Int)] = [:]

        for folder in deviceFolders {
            let fullFolderURL = URL(fileURLWithPath: expandedPath).appendingPathComponent(folder)
            let plistURL = fullFolderURL.appendingPathComponent("device.plist")

            if fileManager.fileExists(atPath: plistURL.path) {
                var versionName = "Unknown Simulator"
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let runtime = plist["runtime"] as? String {
                    versionName = parseRuntimeName(runtime)
                }

                let folderSize = calculateDirectorySize(at: fullFolderURL.path, isDirectory: true)
                if var existing = versionGroups[versionName] {
                    existing.paths.append(fullFolderURL.path)
                    existing.bytes += folderSize
                    existing.count += 1
                    versionGroups[versionName] = existing
                } else {
                    versionGroups[versionName] = (paths: [fullFolderURL.path], bytes: folderSize, count: 1)
                }
            }
        }

        // Only remind if multiple versions (> 1) are detected
        guard versionGroups.keys.count > 1 else {
            return []
        }

        let totalBytes = versionGroups.values.reduce(0) { $0 + $1.bytes }

        let reminderRule = CleanRule(
            name: "Multiple Simulator Versions",
            pathDescription: basePath,
            iconName: "exclamationmark.triangle.fill",
            iconColor: .orange,
            cleanType: .none,
            note: "\(versionGroups.keys.count) Versions",
            isCheckboxHidden: true
        )

        let item = CategoryItem(
            name: reminderRule.name,
            pathDescription: reminderRule.pathDescription,
            iconName: reminderRule.iconName,
            iconColor: reminderRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: formatBytes(totalBytes),
            rule: reminderRule
        )

        return [item]
    }

    private func parseRuntimeName(_ runtime: String) -> String {
        let components = runtime.components(separatedBy: ".")
        guard let last = components.last else { return "Simulator" }

        let parts = last.components(separatedBy: "-")
        if parts.count >= 3 {
            let osType = parts[0]
            let major = parts[1]
            let minor = parts[2]
            return "\(osType) \(major).\(minor)"
        } else if parts.count == 2 {
            return "\(parts[0]) \(parts[1])"
        }
        return last
    }

    // Detect simulator devices whose runtime is no longer installed (unavailable)
    private func scanUnavailableSimulators(basePath: String) -> [CategoryItem] {
        // Availability is not stored in device.plist; ask simctl via JSON output.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return [] // Xcode / simctl not installed on this machine
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? stdout.fileHandleForReading.readToEnd(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [Any]] else {
            return []
        }

        let devicesBasePath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default

        var childItems: [CategoryItem] = []
        var totalBytes: Int64 = 0

        for (_, devices) in devicesByRuntime {
            guard let deviceList = devices as? [[String: Any]] else { continue }
            for device in deviceList {
                // isAvailable may be Bool / String / absent across simctl versions
                let isAvailable: Bool
                if let b = device["isAvailable"] as? Bool {
                    isAvailable = b
                } else if let s = device["isAvailable"] as? String {
                    isAvailable = (s == "1" || s.lowercased() == "true" || s.lowercased() == "yes")
                } else {
                    isAvailable = true
                }
                guard !isAvailable else { continue }
                guard let udid = device["udid"] as? String else { continue }

                let devicePath = (devicesBasePath as NSString).appendingPathComponent(udid)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: devicePath, isDirectory: &isDir), isDir.boolValue else { continue }

                let bytes = calculateDirectorySize(at: devicePath, isDirectory: true)
                guard bytes > 1_000_000 else { continue } // skip trivial device folders

                totalBytes += bytes
                let deviceName = (device["name"] as? String) ?? udid
                let displayPath = "\(basePath)/\(udid)"

                let rule = CleanRule(
                    name: deviceName,
                    pathDescription: displayPath,
                    iconName: "iphone.slash",
                    iconColor: .red,
                    cleanType: .runCommand(executable: "/usr/bin/xcrun", args: ["simctl", "delete", udid]),
                    note: "Unavailable"
                )
                let item = CategoryItem(
                    name: deviceName,
                    pathDescription: displayPath,
                    iconName: "iphone.slash",
                    iconColor: .red,
                    sizeBytes: bytes,
                    sizeString: formatBytes(bytes),
                    rule: rule
                )
                childItems.append(item)
            }
        }

        guard !childItems.isEmpty else { return [] }

        childItems.sort { $0.sizeBytes > $1.sizeBytes }

        let parentRule = CleanRule(
            name: "Unavailable Simulators",
            pathDescription: basePath,
            iconName: "iphone.slash",
            iconColor: .red,
            cleanType: .none,
            note: "Missing Runtime",
            isCheckboxHidden: true
        )
        let parent = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: formatBytes(totalBytes),
            rule: parentRule,
            children: childItems
        )
        return [parent]
    }

    private func normalizeString(_ str: String) -> String {
        normalizeAppIdentifier(str)
    }

    // True if a folder name (under ~/Library/Application Support or ~) corresponds to a
    // currently installed application. Shared by the leftovers and installed-app-data scans
    // so "installed" vs "leftover" can never drift apart.
    private func folderMatchesInstalledApp(_ folder: String, lowerFolder: String, normalizedFolder: String, installedApps: Set<String>) -> Bool {
        let matchesByName = installedApps.contains { appKey in
            guard !appKey.isEmpty else { return false }
            let normalizedAppKey = normalizeString(appKey)
            if lowerFolder == appKey || normalizedFolder == normalizedAppKey {
                return true
            }
            if normalizedFolder.count >= 4 && normalizedAppKey.count >= 4 {
                if normalizedFolder.contains(normalizedAppKey) || normalizedAppKey.contains(normalizedFolder) {
                    return true
                }
            }
            return false
        }
        if matchesByName {
            return true
        }

        // Folders are frequently named after the owning bundle id, which LaunchServices can
        // resolve even when the app itself sits somewhere the bundle walk never reaches.
        return InstalledAppIndex.shared.isRegisteredBundleIdentifier(folder)
    }

    // All currently installed application names and bundle identifiers, from every
    // application directory on the system.
    private func fetchInstalledAppIdentifiers() -> Set<String> {
        InstalledAppIndex.shared.installedIdentifiers()
    }

    // A folder under ~/Library/Application Support that macOS owns: neither a leftover nor
    // installed-app data. Shared by both scans so their verdicts can never drift apart.
    private func isSystemOwnedAppSupportFolder(_ folder: String, lowerFolder: String) -> Bool {
        let isKnownSystemFolder = Self.appSupportSystemIgnoreList.contains { sysKey in
            lowerFolder == sysKey || lowerFolder.hasPrefix(sysKey)
        }
        return isKnownSystemFolder || SystemComponentIndex.shared.isSystemOwned(folder)
    }

    // Shared user-data folders that belong to macOS but are named after a user-facing
    // feature rather than the daemon behind them, so the system volume cannot name them.
    private static let appSupportSystemIgnoreList: Set<String> = [
        "addressbook", "clouddocs", "mobilesync", "dock", "safari", "apple", "com.apple.",
        "accounts", "crashreporter", "defaultappprovider", "knowledge", "quick look",
        "app store", "callhistorydb", "coresimulator", "developer", "system", "syncservices",
        "bluetooth", "preferences", "keychains", "logs", "caches"
    ]

    // Entries directly under ~ that macOS itself creates (standard user folders + system
    // dot-files/metadata) and so should NOT be listed as user/tool-installed items.
    private static let homeSystemEntries: Set<String> = [
        "desktop", "documents", "downloads", "library", "movies", "music",
        "pictures", "public", "applications", "sites",
        ".ds_store", ".localized", ".cfusertextencoding", ".trash", ".fseventsd",
        ".spotlight-v100", ".temporaryitems", ".vol", ".file", ".hotfiles.btree",
        ".documentrevisions-v100", ".pkinstallsandboxmanager", ".zsh_sessions"
    ]

    // Short (<= ~10 char) descriptions for common home-directory entries whose raw name
    // doesn't say what they are. Looked up by lowercased entry name; unknown entries get none.
    private static let homeEntryDescriptions: [String: String] = [
        ".ollama": "Local LLM", ".docker": "Docker Config", ".colima": "Docker Runtime",
        ".orbstack": "Docker Runtime", ".lima": "Docker Runtime", ".minikube": "Local K8s",
        ".cargo": "Rust Packages", ".rustup": "Rust Toolchain", ".gradle": "Gradle Build",
        ".m2": "Maven Repository", ".ivy2": "Ivy Repository", ".npm": "npm Cache", ".pnpm-store": "pnpm Cache",
        ".pnpm-state": "pnpm Cache", ".yarn": "Yarn Cache", ".bun": "Bun Runtime", ".deno": "Deno Cache",
        ".node-gyp": "Build Cache", ".node": "Node Data", ".nvm": "Node Version", ".fnm": "Node Version",
        ".volta": "Node Version", ".asdf": "Version Manager", ".pyenv": "Python Version", ".sdkman": "Java Version",
        ".cocoapods": "iOS Dependencies", ".flutter": "Flutter Config", ".dart": "Dart SDK",
        ".android": "Android SDK", ".aws": "AWS Config", ".kube": "K8s Config", ".ssh": "SSH Keys",
        ".gnupg": "GPG Keys", ".config": "Config Files", ".cache": "General Cache", ".local": "User Data",
        ".gem": "Ruby Gems", ".bundle": "Ruby Dependencies", ".fastlane": "iOS Automation", ".expo": "RN Tools",
        ".cmake": "CMake", ".conan": "C++ Dependencies", ".ipython": "Python Interactive", ".jupyter": "Jupyter",
        ".matplotlib": "Plot Cache", ".helm": "Helm", ".terraform.d": "Terraform",
        ".vagrant.d": "Vagrant", ".putty": "PuTTY", ".cups": "Print Config", ".vscode": "VSCode Config",
        ".cursor": "Cursor Config", ".windsurf": "Windsurf", ".fleet": "Fleet Editor",
        ".claude": "Claude Config", ".cline": "Cline Config", ".copilot": "Copilot Config",
        ".codeium": "Codeium Config", ".gemini": "Gemini Config", ".chatgpt": "ChatGPT Config",
        ".zshrc": "zsh Config", ".zshenv": "zsh Config", ".zprofile": "zsh Config",
        ".bashrc": "bash Config", ".bash_profile": "bash Config", ".profile": "Shell Config",
        ".gitconfig": "Git Config", ".gitignore_global": "Git Ignore", ".npmrc": "npm Config",
        ".yarnrc": "Yarn Config", ".vimrc": "Vim Config", ".vim": "Vim Config",
        ".zsh_history": "Command History", ".bash_history": "Command History", ".mysql_history": "MySQL History",
        ".python_history": "Python History", ".node_repl_history": "Node History",
        ".swiftpm": "Swift Packages", ".switchhosts": "Hosts Manager", ".shadowsocksx-ng": "Proxy Tool",
        ".mitmproxy": "Packet Sniffer", ".termora": "Terminal Tool", ".harmony": "HarmonyOS Dev",
        ".ohos": "HarmonyOS Dev", ".ohpm": "HarmonyOS Packages", ".hvigor": "HarmonyOS Build", ".aliyun": "Aliyun CLI",
        "flutter": "Flutter SDK", "venvs": "Python Venvs", "androidstudioprojects": "Android Projects",
        "wechatprojects": "WeChat Projects", "codegeexprojects": "CodeGeeX Projects",
        "writersideprojects": "Writerside Projects", "postman": "API Testing", "plugins": "Plugins",
        "creative cloud files": "Adobe Cloud Files", "yarn.lock": "Dependency Lock",
        ".alibabacloud": "Aliyun CLI", ".tencentcloud": "Tencent CLI", ".wechat_devtools": "WeChat Projects",
        ".codegeex": "CodeGeeX Projects", ".writerside": "Writerside Projects"
    ]

    // Custom SF Symbols and colors for known home directory entries.
    private static let homeEntryIcons: [String: (String, Color)] = [
        ".gradle": ("cup.and.saucer.fill", .teal),
        ".android": ("candybarphone", .green),
        ".npm": ("shippingbox.fill", .red),
        ".gemini": ("sparkles", .indigo),
        ".konan": ("hammer.fill", .purple),
        "flutter": ("paperplane.fill", .cyan), // Fixed typo (was .flutter)
        ".ollama": ("brain.head.profile", .gray),
        ".cocoapods": ("square.stack.3d.down.right.fill", .red),
        ".rustup": ("gearshape.2.fill", .orange),
        ".cargo": ("shippingbox.fill", .orange),
        ".expo": ("arrow.up.forward.app.fill", .gray),
        ".nvm": ("network", .green),
        ".sdkman": ("wrench.and.screwdriver.fill", .gray),
        ".local": ("folder.badge.gearshape", .secondary),
        ".cursor": ("cursorarrow", .blue),
        ".cache": ("archivebox.fill", .secondary),
        ".config": ("gearshape.fill", .secondary),
        ".ssh": ("key.fill", .gray),
        ".gnupg": ("lock.shield.fill", .gray),
        ".docker": ("cube.fill", .blue),
        ".m2": ("cup.and.saucer.fill", .indigo),
        ".pnpm-store": ("shippingbox.fill", .teal),
        ".yarn": ("shippingbox.fill", .blue),
        ".bun": ("shippingbox.fill", .pink),
        ".colima": ("cube.fill", .blue),
        ".orbstack": ("cube.fill", .blue),
        ".lima": ("cube.fill", .blue),
        ".minikube": ("cube.fill", .blue),
        ".ivy2": ("cup.and.saucer.fill", .indigo),
        ".pnpm-state": ("shippingbox.fill", .teal),
        ".deno": ("shippingbox.fill", .green),
        ".node-gyp": ("hammer.fill", .gray),
        ".node": ("network", .green),
        ".fnm": ("network", .green),
        ".volta": ("network", .green),
        ".asdf": ("square.stack.3d.down.right.fill", .gray),
        ".pyenv": ("curlybraces", .yellow),
        ".dart": ("paperplane.fill", .cyan),
        ".aws": ("cloud.fill", .orange),
        ".kube": ("network", .blue),
        ".gem": ("diamond.fill", .red),
        ".bundle": ("shippingbox.fill", .red),
        ".fastlane": ("car.fill", .mint),
        ".cmake": ("hammer.fill", .gray),
        ".conan": ("shippingbox.fill", .blue),
        ".ipython": ("curlybraces", .yellow),
        ".jupyter": ("book.fill", .orange),
        ".matplotlib": ("chart.bar.fill", .blue),
        ".helm": ("sailboat.fill", .blue),
        ".terraform.d": ("globe", .purple),
        ".vagrant.d": ("cube.fill", .blue),
        ".putty": ("terminal.fill", .gray),
        ".cups": ("printer.fill", .gray),
        ".vscode": ("chevron.left.forwardslash.chevron.right", .blue),
        ".windsurf": ("wind", .cyan),
        ".fleet": ("paperplane.fill", .blue),
        ".claude": ("sparkles", .orange),
        ".cline": ("sparkles", .blue),
        ".copilot": ("sparkles", .purple),
        ".codeium": ("sparkles", .green),
        ".chatgpt": ("sparkles", .green),
        ".zshrc": ("terminal.fill", .gray),
        ".zshenv": ("terminal.fill", .gray),
        ".zprofile": ("terminal.fill", .gray),
        ".bashrc": ("terminal.fill", .gray),
        ".bash_profile": ("terminal.fill", .gray),
        ".profile": ("terminal.fill", .gray),
        ".gitconfig": ("arrow.triangle.branch", .orange),
        ".gitignore_global": ("doc.text.fill", .orange),
        ".npmrc": ("doc.text.fill", .red),
        ".yarnrc": ("doc.text.fill", .blue),
        ".vimrc": ("terminal.fill", .green),
        ".vim": ("terminal.fill", .green),
        ".zsh_history": ("clock.fill", .gray),
        ".bash_history": ("clock.fill", .gray),
        ".mysql_history": ("clock.fill", .gray),
        ".python_history": ("clock.fill", .gray),
        ".node_repl_history": ("clock.fill", .gray),
        ".swiftpm": ("swift", .orange),
        ".switchhosts": ("network", .gray),
        ".shadowsocksx-ng": ("paperplane.fill", .blue),
        ".mitmproxy": ("network", .gray),
        ".termora": ("terminal.fill", .gray),
        ".harmony": ("cube.fill", .blue),
        ".ohos": ("cube.fill", .blue),
        ".ohpm": ("shippingbox.fill", .blue),
        ".hvigor": ("hammer.fill", .blue),
        ".aliyun": ("cloud.fill", .orange),
        ".alibabacloud": ("cloud.fill", .orange),
        ".tencentcloud": ("cloud.fill", .blue),
        ".wechat_devtools": ("hammer.fill", .green),
        ".codegeex": ("sparkles", .purple),
        ".writerside": ("book.fill", .blue),
        "venvs": ("curlybraces", .yellow),
        "androidstudioprojects": ("candybarphone", .green),
        "wechatprojects": ("bubble.left.fill", .green),
        "codegeexprojects": ("sparkles", .purple),
        "writersideprojects": ("book.fill", .blue),
        "postman": ("paperplane.fill", .orange),
        "plugins": ("puzzlepiece.fill", .gray),
        "creative cloud files": ("cloud.fill", .red),
        "yarn.lock": ("lock.fill", .blue)
    ]

    private enum DirectoryContentKind: CaseIterable {
        case keysAndLicenses
        case userData
        case browserBridge
        case crashReports
        case telemetry
        case updater
        case logs
        case cache
        case settings

        var baseScore: Int {
            switch self {
            case .keysAndLicenses: return 12
            case .browserBridge: return 10
            case .userData: return 8
            case .crashReports, .telemetry, .updater, .logs, .cache: return 6
            case .settings: return 5
            }
        }

        var note: LocalizedStringKey {
            switch self {
            case .keysAndLicenses: return "Keys & Licenses"
            case .userData: return "User Data"
            case .browserBridge: return "Browser Bridge"
            case .crashReports: return "Crash Reports"
            case .telemetry: return "Telemetry"
            case .updater: return "Updater"
            case .logs: return "Logs"
            case .cache: return "Cache"
            case .settings: return "Settings"
            }
        }
    }

    // Describe only the kinds of content found in a directory. This classification is
    // deliberately independent from whether the directory is a leftover or safe to delete.
    // Sampling is bounded so it works for arbitrary apps without making scans unreasonably slow.
    private func describeDirectoryContents(at path: String) -> LocalizedStringKey? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return nil }
        let ignoredMetadata = Set([".ds_store", ".localized"])
        guard entries.contains(where: { !ignoredMetadata.contains($0.lowercased()) }) else {
            return "Empty"
        }

        var scores = Dictionary(
            uniqueKeysWithValues: DirectoryContentKind.allCases.map { ($0, 0) }
        )
        var seenSignals = Dictionary(
            uniqueKeysWithValues: DirectoryContentKind.allCases.map { ($0, Set<String>()) }
        )

        func words(in value: String) -> Set<String> {
            Set(
                value.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
            )
        }

        func inspect(_ rawName: String, depth: Int) {
            let name = rawName.lowercased()
            guard !ignoredMetadata.contains(name) else { return }

            let nameWords = words(in: name)
            let depthBonus = max(0, 4 - depth)

            func hasAnyWord(_ candidates: Set<String>) -> Bool {
                !nameWords.isDisjoint(with: candidates)
            }

            func containsAny(_ candidates: [String]) -> Bool {
                candidates.contains { name.contains($0) }
            }

            func hasAnySuffix(_ candidates: [String]) -> Bool {
                candidates.contains { name.hasSuffix($0) }
            }

            func record(_ kind: DirectoryContentKind, when matched: Bool) {
                guard matched, seenSignals[kind, default: []].insert(name).inserted else {
                    return
                }
                scores[kind, default: 0] = min(
                    24,
                    scores[kind, default: 0] + kind.baseScore + depthBonus
                )
            }

            record(
                .keysAndLicenses,
                when: hasAnyWord([
                    "credential", "credentials", "license", "licenses", "licence", "licences",
                    "keychain", "keystore", "truststore", "secret", "secrets", "certificate",
                    "certificates", "token", "tokens"
                ]) || hasAnySuffix([
                    ".pem", ".key", ".p12", ".pfx", ".cer", ".crt", ".mobileprovision"
                ])
            )
            record(
                .userData,
                when: hasAnyWord([
                    "document", "documents", "project", "projects", "workspace", "workspaces",
                    "session", "sessions", "conversation", "conversations", "history", "histories",
                    "profile", "profiles", "preset", "presets", "template", "templates",
                    "connection", "connections", "conn", "database", "databases", "bookmark",
                    "bookmarks", "myplaces", "inventory"
                ]) || hasAnySuffix([".fcpworkspace", ".sublime_session"])
            )
            record(
                .browserBridge,
                when: containsAny(["nativemessaginghosts", "native-messaging-hosts"])
            )
            record(
                .crashReports,
                when: hasAnyWord(["crash", "crashes"]) || containsAny([
                    "crashreport", "crash-report", "crashpad", "kscrash", "bugsnag", "bugly",
                    "sentry"
                ])
            )
            record(
                .telemetry,
                when: hasAnyWord(["telemetry", "analytics"]) || containsAny([
                    "segment-events", "usage-statistics", "usage_statistics", "countly"
                ])
            )
            record(
                .updater,
                when: hasAnyWord(["update", "updates", "updater", "installer"])
            )
            record(
                .logs,
                when: hasAnyWord(["log", "logs", "diagnostic", "diagnostics"])
                    || hasAnySuffix([".log"])
            )
            record(
                .cache,
                when: hasAnyWord([
                    "cache", "caches", "cached", "temp", "tmp", "temporary", "thumbnail",
                    "thumbnails"
                ])
            )
            record(
                .settings,
                when: hasAnyWord([
                    "config", "configs", "configuration", "settings", "setting", "preferences",
                    "preference", "options", "prefs", "pref"
                ]) || hasAnySuffix([".plist", ".ini"])
            )
        }

        // The app/vendor folder name can carry useful evidence (for example, an updater
        // or crash-reporting framework), but receives no depth bonus.
        inspect((path as NSString).lastPathComponent, depth: 4)

        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey]
        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) {
            let maxDepth = 6
            let maxEntries = 256
            var sampledEntries = 0

            while sampledEntries < maxEntries,
                  let itemURL = enumerator.nextObject() as? URL {
                let depth = enumerator.level
                if depth > maxDepth {
                    enumerator.skipDescendants()
                    continue
                }

                inspect(itemURL.lastPathComponent, depth: depth)
                sampledEntries += 1

                if depth == maxDepth,
                   (try? itemURL.resourceValues(forKeys: Set(resourceKeys)).isDirectory) == true {
                    enumerator.skipDescendants()
                }
            }
        }

        let ranked = scores
            .filter { $0.value > 0 }
            .sorted {
                if $0.value == $1.value {
                    return $0.key.baseScore > $1.key.baseScore
                }
                return $0.value > $1.value
            }

        guard let strongest = ranked.first else { return "App Data" }
        if ranked.count > 1 {
            let secondScore = ranked[1].value
            if secondScore >= 6, secondScore * 5 >= strongest.value * 3 {
                return "Mixed Data"
            }
        }
        return strongest.key.note
    }

    // Dynamically scan for folders in Application Support that belong to UNINSTALLED applications
    private func scanAppLeftovers(basePath: String) -> [CategoryItem] {
        let expandedBasePath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default
        guard let subfolders = try? fileManager.contentsOfDirectory(atPath: expandedBasePath) else {
            return []
        }

        let installedApps = fetchInstalledAppIdentifiers()

        var childItems: [CategoryItem] = []
        var totalBytes: Int64 = 0

        for folder in subfolders {
            if folder.hasPrefix(".") || folder.hasSuffix("_Lock") {
                continue
            }

            let lowerFolder = folder.lowercased()
            let normalizedFolder = normalizeString(folder)

            // 1. Check if folder belongs to macOS itself
            if isSystemOwnedAppSupportFolder(folder, lowerFolder: lowerFolder) {
                continue
            }

            // 2. Check if folder belongs to an installed command-line tool or package
            if InstalledToolIndex.shared.isInstalledTool(folder) {
                continue
            }

            // 3. Check if folder matches any installed application
            let isAppInstalled = folderMatchesInstalledApp(folder, lowerFolder: lowerFolder, normalizedFolder: normalizedFolder, installedApps: installedApps)

            // If the app is currently installed, SKIP IT (Not a leftover!)
            if isAppInstalled {
                continue
            }

            let fullPath = (expandedBasePath as NSString).appendingPathComponent(folder)
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                let sizeBytes = calculateDirectorySize(at: fullPath, isDirectory: true)
                totalBytes += sizeBytes
                let displayPath = "\(basePath)/\(folder)"
                let childRule = CleanRule(
                    name: folder,
                    pathDescription: displayPath,
                    iconName: "folder.badge.minus",
                    iconColor: .pink,
                    cleanType: .deleteDirectoryTree,
                    note: describeDirectoryContents(at: fullPath)
                )

                let childItem = CategoryItem(
                    name: childRule.name,
                    pathDescription: childRule.pathDescription,
                    iconName: childRule.iconName,
                    iconColor: childRule.iconColor,
                    sizeBytes: sizeBytes,
                    sizeString: formatBytes(sizeBytes),
                    rule: childRule
                )
                childItems.append(childItem)
            }
        }

        guard !childItems.isEmpty else { return [] }

        childItems.sort { $0.name.lowercased() < $1.name.lowercased() }

        let parentRule = CleanRule(
            name: "Uninstalled App Leftovers",
            pathDescription: basePath,
            iconName: "folder.fill",
            iconColor: .pink,
            cleanType: .none,
            note: "App Leftovers",
            isCheckboxHidden: true
        )

        let parentItem = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: formatBytes(totalBytes),
            rule: parentRule,
            children: childItems
        )

        return [parentItem]
    }

    // Dynamically scan ~/Library/Containers for sandbox containers whose owning
    // application is no longer installed. Unlike Application Support (folders named
    // by app display name), container directories are named by bundle id -- or by a
    // UUID, in which case the real owning bundle id lives in each container's
    // .com.apple.containermanagerd.metadata.plist (MCMMetadataIdentifier). That
    // plist is read so UUID-named containers resolve correctly. com.apple.* system
    // containers are always skipped. Remaining containers whose bundle id matches
    // no installed app (or its extensions) are listed as cleanable leftovers.
    private func scanContainerLeftovers(basePath: String) -> (items: [CategoryItem], accessDenied: Bool) {
        let expandedBasePath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: expandedBasePath) else {
            return ([], false)
        }

        let installedApps = fetchInstalledAppIdentifiers()

        var childItems: [CategoryItem] = []
        var totalBytes: Int64 = 0

        for entry in entries {
            let fullPath = (expandedBasePath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Resolve the owning bundle id from the container manager metadata plist,
            // falling back to the folder name. UUID-named containers rely on the plist.
            let metadataPlist = (fullPath as NSString).appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            var bundleID = entry
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: metadataPlist))
                if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let identifier = plist["MCMMetadataIdentifier"] as? String,
                   !identifier.isEmpty {
                    bundleID = identifier
                }
            } catch {
                let nsError = error as NSError
                let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                let underlyingPermissionDenied = underlyingError.map {
                    $0.domain == NSPOSIXErrorDomain
                        && ($0.code == POSIXErrorCode.EPERM.rawValue
                            || $0.code == POSIXErrorCode.EACCES.rawValue)
                } ?? false
                let permissionDenied = nsError.code == NSFileReadNoPermissionError
                    || underlyingPermissionDenied
                if permissionDenied {
                    return ([], true)
                }
            }

            let lowerBundle = bundleID.lowercased()

            // Skip macOS system containers (system services, daemons, built-in apps).
            if lowerBundle.hasPrefix("com.apple.") { continue }

            // Skip containers whose owning app -- or one of its extensions -- is still
            // installed. Extension containers (e.g. "com.foo.app.ShareExtension") and
            // team-id-prefixed containers match via substring against the app bundle id.
            let normalizedBundle = normalizeString(bundleID)
            if folderMatchesInstalledApp(bundleID, lowerFolder: lowerBundle, normalizedFolder: normalizedBundle, installedApps: installedApps) {
                continue
            }

            let sizeBytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            totalBytes += sizeBytes
            let displayPath = "\(basePath)/\(entry)"
            // A container's contents live under Data/, which is the app's redirected home.
            let dataPath = (fullPath as NSString).appendingPathComponent("Data")
            let childRule = CleanRule(
                name: entry,
                pathDescription: displayPath,
                iconName: "shippingbox.fill",
                iconColor: .pink,
                cleanType: .deleteDirectoryTree,
                note: describeDirectoryContents(at: dataPath) ?? describeDirectoryContents(at: fullPath)
            )

            let childItem = CategoryItem(
                name: childRule.name,
                pathDescription: childRule.pathDescription,
                iconName: childRule.iconName,
                iconColor: childRule.iconColor,
                sizeBytes: sizeBytes,
                sizeString: formatBytes(sizeBytes),
                rule: childRule
            )
            childItems.append(childItem)
        }

        guard !childItems.isEmpty else { return ([], false) }

        childItems.sort { $0.sizeBytes > $1.sizeBytes }

        let parentRule = CleanRule(
            name: String(localized: "Container Leftovers"),
            pathDescription: basePath,
            iconName: "shippingbox.fill",
            iconColor: .pink,
            cleanType: .none,
            note: "Container Leftovers",
            isCheckboxHidden: true
        )

        let parentItem = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: formatBytes(totalBytes),
            rule: parentRule,
            children: childItems
        )

        return ([parentItem], false)
    }

    // Read-only analysis of containers owned by apps that are still installed.
    // Access to another app's sandbox can require Full Disk Access even though
    // this scan never modifies the container.
    private func scanInstalledAppContainers() -> (item: CategoryItem?, accessDenied: Bool) {
        let basePaths = [
            "~/Library/Containers",
            "~/Library/Group Containers"
        ]
        let fileManager = FileManager.default
        let installedApps = fetchInstalledAppIdentifiers()
        var childItems: [CategoryItem] = []
        var accessDenied = false

        for basePath in basePaths {
            let expandedBasePath = NSString(string: basePath).expandingTildeInPath
            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: expandedBasePath)
            } catch {
                accessDenied = accessDenied || isPermissionDenied(error)
                continue
            }

            for entry in entries {
                let fullPath = (expandedBasePath as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                let metadataPath = (fullPath as NSString)
                    .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                var bundleID = entry
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
                    if let plist = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                    ) as? [String: Any],
                       let identifier = plist["MCMMetadataIdentifier"] as? String,
                       !identifier.isEmpty {
                        bundleID = identifier
                    }
                } catch {
                    accessDenied = accessDenied || isPermissionDenied(error)
                }

                let lowerBundle = bundleID.lowercased()
                if lowerBundle.hasPrefix("com.apple.") { continue }

                let normalizedBundle = normalizeString(bundleID)
                guard folderMatchesInstalledApp(
                    bundleID,
                    lowerFolder: lowerBundle,
                    normalizedFolder: normalizedBundle,
                    installedApps: installedApps
                ) else { continue }

                let sizeResult = calculateDirectorySizeReportingAccess(at: fullPath)
                accessDenied = accessDenied || sizeResult.accessDenied
                guard sizeResult.bytes > 1_000_000 else { continue }

                childItems.append(displayItem(
                    name: bundleID,
                    label: "\(basePath)/\(entry)",
                    icon: "shippingbox.fill",
                    color: .blue,
                    sizeBytes: sizeResult.bytes,
                    finderPath: fullPath,
                    description: "App Container"
                ))
            }
        }

        guard !childItems.isEmpty else { return (nil, accessDenied) }
        childItems.sort { $0.sizeBytes > $1.sizeBytes }
        return (
            displayParent(
                name: "Installed App Containers",
                label: "Installed App Containers",
                icon: "shippingbox.fill",
                color: .blue,
                note: "Read Only",
                children: childItems,
                finderPath: NSString(string: "~/Library/Containers").expandingTildeInPath
            ),
            accessDenied
        )
    }

    private func calculateDirectorySizeReportingAccess(
        at path: String
    ) -> (bytes: Int64, accessDenied: Bool) {
        var accessDenied = false
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            errorHandler: { _, error in
                accessDenied = accessDenied || isPermissionDenied(error)
                return true
            }
        ) else {
            return (0, true)
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               values.isDirectory == false,
               let size = values.fileSize {
                totalBytes += Int64(size)
            }
        }
        return (totalBytes, accessDenied)
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError
            || nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == POSIXErrorCode.EPERM.rawValue
            || nsError.code == POSIXErrorCode.EACCES.rawValue {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlyingError)
        }
        return false
    }

    // Scan known tool cache locations under the home directory
    private func scanHomeCaches(basePath: String) -> [CategoryItem] {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default

        // Curated, safe-to-clear tool caches (contents only; folder is kept)
        let knownCaches: [(name: String, subpath: String, icon: String, color: Color)] = [
            ("XDG Cache", ".cache", "shippingbox.fill", .orange),
            ("Gradle Cache", ".gradle/caches", "hammer.fill", .purple),
            ("Gradle Wrapper Distributions", ".gradle/wrapper/dists", "hammer.fill", .purple),
            ("npm Cache", ".npm/_cacache", "shippingbox.fill", .red),
            ("npx Cache", ".npm/_npx", "shippingbox.fill", .red),
            ("pnpm Store", ".pnpm-store", "shippingbox.fill", .teal),
            ("pnpm Store (macOS)", "Library/pnpm", "shippingbox.fill", .teal),
            ("Yarn Cache", ".yarn/cache", "shippingbox.fill", .blue),
            ("Yarn Berry Cache", ".yarn/berry/cache", "shippingbox.fill", .cyan),
            ("Bun Cache", ".bun/install/cache", "shippingbox.fill", .pink),
            ("node-gyp Cache", ".node-gyp", "hammer.fill", .gray),
            ("Deno Cache", ".deno/deps", "shippingbox.fill", .green),
            ("Maven Repository", ".m2/repository", "shippingbox.fill", .indigo),
            ("Cargo Registry Cache", ".cargo/registry", "shippingbox.fill", .orange),
            ("Cargo Git Cache", ".cargo/git", "shippingbox.fill", .orange)
        ]

        var childItems: [CategoryItem] = []
        var totalBytes: Int64 = 0

        for cache in knownCaches {
            let fullPath = (home as NSString).appendingPathComponent(cache.subpath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let bytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            guard bytes > 1_000_000 else { continue } // skip trivial caches

            totalBytes += bytes
            let displayPath = "~/\(cache.subpath)"
            let rule = CleanRule(
                name: cache.name,
                pathDescription: displayPath,
                iconName: cache.icon,
                iconColor: cache.color,
                cleanType: .deleteDirectory,
                note: LocalizedStringKey(cache.name)
            )
            let item = CategoryItem(
                name: cache.name,
                pathDescription: displayPath,
                iconName: cache.icon,
                iconColor: cache.color,
                sizeBytes: bytes,
                sizeString: formatBytes(bytes),
                rule: rule
            )
            childItems.append(item)
        }

        return childItems
    }

    // MARK: - Installed Tools (read-only informational section)

    // GUI apps don't inherit the user's shell PATH; ask the login shell for it.
    private func userPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ProcessInfo.processInfo.environment["PATH"] ?? ""
        }
        // Login shells return instantly; guard against a shell that waits for input.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let out = String(data: data, encoding: .utf8) else {
            return ProcessInfo.processInfo.environment["PATH"] ?? ""
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (ProcessInfo.processInfo.environment["PATH"] ?? "") : trimmed
    }

    // Parse $PATH (from the user's shell) into non-system bin directories that exist,
    // supplemented with common non-system tool dirs for robustness.
    private func nonSystemPathDirs() -> [String] {
        let home = NSHomeDirectory()
        let systemPrefixes = [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/System", "/Library", "/usr/libexec", "/usr/lib",
            "/AppleInternal", "/opt/Xcode", "/Applications"
        ]

        var seen = Set<String>()
        var result: [String] = []

        func consider(_ dir: String) {
            let isSystem = systemPrefixes.contains { dir == $0 || dir.hasPrefix($0 + "/") }
            if isSystem { return }
            if dir.contains("/Xcode.app/") || dir.contains("/Toolchains/") || dir.contains("/Developer/") {
                return
            }
            let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            if seen.contains(resolved) { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                seen.insert(resolved)
                result.append(resolved)
            }
        }

        for raw in userPath().split(separator: ":", omittingEmptySubsequences: true) {
            var dir = String(raw)
            if dir.hasPrefix("~/") {
                dir = (home as NSString).appendingPathComponent(String(dir.dropFirst(2)))
            }
            consider(dir)
        }
        // Supplement with common non-system tool dirs (robustness for GUI-launched apps)
        let common = [
            "/opt/homebrew/bin", "/usr/local/bin",
            (home as NSString).appendingPathComponent(".cargo/bin"),
            (home as NSString).appendingPathComponent(".local/bin"),
            (home as NSString).appendingPathComponent("go/bin"),
            (home as NSString).appendingPathComponent(".deno/bin"),
            (home as NSString).appendingPathComponent(".bun/bin"),
            (home as NSString).appendingPathComponent(".volta/bin"),
            (home as NSString).appendingPathComponent(".yarn/bin"),
            (home as NSString).appendingPathComponent("Library/pnpm")
        ]
        for d in common { consider(d) }
        return result
    }

    // Run an executable and return trimmed stdout, or nil on failure.
    private func runCommandCapture(_ executable: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Full path of `name` if present and executable in any of `dirs`.
    private func locateBinary(_ name: String, in dirs: [String]) -> String? {
        for dir in dirs {
            let full = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    // Sorted executable file names in a directory.
    private func binariesInDir(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var result = Set<String>()
        for name in names {
            let full = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: full) {
                result.insert(name)
            }
        }
        return result.sorted()
    }

    // Package names inside a node_modules directory (handles @scope/pkg).
    private func packagesInNodeModules(_ dir: String) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var pkgs: [String] = []
        for item in items {
            if item.hasPrefix(".") { continue }
            if item.hasPrefix("@") {
                let scopeDir = (dir as NSString).appendingPathComponent(item)
                if let inner = try? fm.contentsOfDirectory(atPath: scopeDir) {
                    for p in inner where !p.hasPrefix(".") {
                        pkgs.append("\(item)/\(p)")
                    }
                }
            } else {
                pkgs.append(item)
            }
        }
        return pkgs.sorted()
    }

    // Convenience builder for read-only display nodes.
    private func displayItem(name: String, label: String, icon: String, color: Color, note: LocalizedStringKey? = nil, children: [CategoryItem]? = nil, sizeBytes: Int64 = 0, finderPath: String? = nil, description: LocalizedStringKey? = nil) -> CategoryItem {
        CategoryItem(
            name: name,
            pathDescription: label,
            iconName: icon,
            iconColor: color,
            sizeBytes: sizeBytes,
            sizeString: sizeBytes > 0 ? formatBytes(sizeBytes) : "",
            rule: CleanRule(name: name, pathDescription: label, iconName: icon, iconColor: color, cleanType: .none, note: note),
            children: children,
            isDisplayOnly: true,
            finderPath: finderPath,
            description: description
        )
    }

    // Display parent whose size is the sum of its children's sizes.
    private func displayParent(name: String, label: String, icon: String, color: Color, note: LocalizedStringKey? = nil, children: [CategoryItem], finderPath: String? = nil) -> CategoryItem {
        let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return displayItem(name: name, label: label, icon: icon, color: color, note: note, children: children, sizeBytes: total, finderPath: finderPath)
    }

    // A read-only leaf module with an optional on-disk size and Finder location.
    private func leaf(_ name: String, _ size: Int64 = 0, finderPath: String? = nil, description: LocalizedStringKey? = nil) -> CategoryItem {
        displayItem(name: name, label: name, icon: "circle.fill", color: .secondary, sizeBytes: size, finderPath: finderPath, description: description)
    }

    // Parse `gem environment` for GEM PATHS entries (lines like "     - /path").
    private func gemPaths(gemPath: String) -> [String] {
        guard let out = runCommandCapture(gemPath, ["environment"]) else { return [] }
        var seen = Set<String>()
        var paths: [String] = []
        let regex = try? NSRegularExpression(pattern: "^\\s+-\\s+(/.+)$")
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            if let m = regex?.firstMatch(in: line, options: [], range: range),
               let r = Range(m.range(at: 1), in: line) {
                let p = String(line[r]).trimmingCharacters(in: .whitespaces)
                if seen.insert(p).inserted { paths.append(p) }
            }
        }
        return paths
    }

    // Extract a gem's name from its gems/ directory entry (e.g. "net-http-persistent-4.0.0" -> "net-http-persistent").
    private func gemName(from entry: String) -> String? {
        let chars = Array(entry)
        var i = 0
        while i < chars.count {
            if chars[i] == "-", i + 1 < chars.count, chars[i + 1].isNumber {
                return String(chars[0..<i])
            }
            i += 1
        }
        return nil
    }

    // Top-level package names in a node_modules dir, each paired with its on-disk size.
    private func sizedPackages(in nodeModules: String) -> [(name: String, size: Int64)] {
        packagesInNodeModules(nodeModules).map { name in
            let dir = (nodeModules as NSString).appendingPathComponent(name)
            return (name, calculateDirectorySize(at: dir, isDirectory: true))
        }
    }

    // normalized .app name -> full path, for /Applications and ~/Applications (used to size casks).
    private func appSizeMap() -> [String: String] {
        var map: [String: String] = [:]
        let dirs = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        let fm = FileManager.default
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for name in names where name.hasSuffix(".app") {
                let key = normalizeString((name as NSString).deletingPathExtension)
                map[key] = (d as NSString).appendingPathComponent(name)
            }
        }
        return map
    }

    // Enumerate every Node.js installation on the system (nvm/fnm/volta/asdf/nodenv/n,
    // Homebrew, /usr/local, npmrc/env prefix, active PATH) and list each one's global
    // packages. Users often have several side by side, so we scan the filesystem rather
    // than trusting only the active `npm` in PATH.
    private func scanNodeInstalls(dirs: [String], ownedDirs: inout Set<String>) -> CategoryItem? {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var roots: [(label: String, prefix: String)] = []
        var seen = Set<String>()

        func addPrefix(_ label: String, _ prefix: String, requireNodeBinary: Bool = true) {
            let resolved = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path
            if requireNodeBinary {
                let nodeBin = (resolved as NSString).appendingPathComponent("bin/node")
                guard fm.fileExists(atPath: nodeBin) else { return }
            } else {
                let nm = (resolved as NSString).appendingPathComponent("lib/node_modules")
                guard fm.fileExists(atPath: nm) else { return }
            }
            if seen.insert(resolved).inserted {
                roots.append((label, resolved))
            }
        }

        func addVersions(_ baseDir: String, manager: String, suffix: String = "") {
            guard let versions = try? fm.contentsOfDirectory(atPath: baseDir) else { return }
            for v in versions.sorted() {
                var root = (baseDir as NSString).appendingPathComponent(v)
                if !suffix.isEmpty { root = (root as NSString).appendingPathComponent(suffix) }
                let ver = v.hasPrefix("v") ? String(v.dropFirst()) : v
                addPrefix("\(manager) \(ver)", root)
            }
        }

        addVersions((home as NSString).appendingPathComponent(".nvm/versions/node"), manager: "nvm")
        addVersions((home as NSString).appendingPathComponent(".fnm/node-versions"), manager: "fnm", suffix: "installation")
        addVersions((home as NSString).appendingPathComponent("Library/Application Support/fnm/node-versions"), manager: "fnm", suffix: "installation")
        addVersions((home as NSString).appendingPathComponent(".volta/tools/image/node"), manager: "volta")
        addVersions((home as NSString).appendingPathComponent(".asdf/installs/nodejs"), manager: "asdf")
        addVersions((home as NSString).appendingPathComponent(".nodenv/versions"), manager: "nodenv")
        let nPrefix = ProcessInfo.processInfo.environment["N_PREFIX"] ?? (home as NSString).appendingPathComponent("n")
        addVersions((nPrefix as NSString).appendingPathComponent("n/versions/node"), manager: "n")
        addVersions("/usr/local/n/versions/node", manager: "n")
        addPrefix("Homebrew", "/opt/homebrew")
        addPrefix("/usr/local", "/usr/local")
        // custom global prefix from env or ~/.npmrc (no node binary lives there)
        if let envPrefix = ProcessInfo.processInfo.environment["NPM_CONFIG_PREFIX"], !envPrefix.isEmpty {
            addPrefix("npm prefix (env)", envPrefix, requireNodeBinary: false)
        }
        let npmrc = (home as NSString).appendingPathComponent(".npmrc")
        if let content = try? String(contentsOfFile: npmrc, encoding: .utf8) {
            for raw in content.split(separator: "\n") {
                let s = String(raw).trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix("prefix") else { continue }
                let parts = s.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty {
                        let expanded = val.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(val.dropFirst(2))) : val
                        addPrefix("npmrc \(val)", expanded, requireNodeBinary: false)
                    }
                }
            }
        }
        // Active npm in PATH (fallback for any install not covered above)
        if let npmPath = locateBinary("npm", in: dirs) {
            if let nm = runCommandCapture(npmPath, ["root", "-g"]), !nm.isEmpty {
                let libDir = (nm as NSString).deletingLastPathComponent
                addPrefix("PATH (active)", (libDir as NSString).deletingLastPathComponent)
            }
        }

        if roots.isEmpty { return nil }

        var installNodes: [CategoryItem] = []
        for (label, prefix) in roots {
            let nm = (prefix as NSString).appendingPathComponent("lib/node_modules")
            let pkgs = fm.fileExists(atPath: nm) ? sizedPackages(in: nm) : []
            ownedDirs.insert((prefix as NSString).appendingPathComponent("bin"))
            let displayLabel = "\(label)  (\(pkgs.count))"
            if pkgs.isEmpty {
                installNodes.append(displayItem(name: label, label: displayLabel, icon: "shippingbox.fill", color: .green, note: "No Global Packages", finderPath: nm.isEmpty ? nil : nm))
            } else {
                let children = pkgs.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (nm as NSString).appendingPathComponent($0.0)) }
                installNodes.append(displayParent(name: label, label: displayLabel, icon: "shippingbox.fill", color: .green, children: children, finderPath: nm))
            }
        }

        return displayParent(name: "Node.js", label: "Node.js", icon: "shippingbox.fill", color: .green, children: installNodes)
    }

    // Full paths of the home-root entries the Home Directory section lists (non-system,
    // non-iCloud). Used to avoid showing the same data twice in Installed Tools.
    private func homeDirectoryEntryPaths() -> Set<String> {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home) else { return [] }
        var paths = Set<String>()
        for entry in entries {
            let lower = entry.lowercased()
            if Self.homeSystemEntries.contains(lower) { continue }
            if lower.hasPrefix("icloud") { continue }
            let resolved = URL(fileURLWithPath: (home as NSString).appendingPathComponent(entry)).resolvingSymlinksInPath().path
            paths.insert(resolved)
        }
        return paths
    }

    // True if `path` falls under one of the home-root entries shown in Home Directory.
    private func isPathCoveredByHome(_ path: String, coveredPaths: Set<String>) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return coveredPaths.contains { entryPath in
            resolved == entryPath || resolved.hasPrefix(entryPath + "/")
        }
    }

    // Recursively drop nodes whose location is already shown in Home Directory, recompute
    // parent sizes, and prune parents that become empty as a result.
    private func filterHomeCoveredNodes(_ items: [CategoryItem], coveredPaths: Set<String>) -> [CategoryItem] {
        var result: [CategoryItem] = []
        for item in items {
            if let fp = item.finderPath, isPathCoveredByHome(fp, coveredPaths: coveredPaths) {
                continue
            }
            if let children = item.children, !children.isEmpty {
                let filtered = filterHomeCoveredNodes(children, coveredPaths: coveredPaths)
                if filtered.isEmpty { continue }
                var rebuilt = item
                rebuilt.children = filtered
                rebuilt.sizeBytes = filtered.reduce(Int64(0)) { $0 + $1.sizeBytes }
                rebuilt.sizeString = rebuilt.sizeBytes > 0 ? formatBytes(rebuilt.sizeBytes) : ""
                result.append(rebuilt)
            } else {
                result.append(item)
            }
        }
        return result
    }

    // Build the read-only "Installed Tools" tree from non-system PATH tools and their modules.
    // Only top-level / user-installed packages are listed; each carries a best-effort on-disk size.
    private func scanInstalledTools() -> CategoryItem {
        let dirs = nonSystemPathDirs()
        let home = NSHomeDirectory()
        let fm = FileManager.default

        func trimLines(_ s: String) -> [String] {
            s.split(separator: "\n")
             .map { String($0).trimmingCharacters(in: .whitespaces) }
             .filter { !$0.isEmpty }
        }

        var toolNodes: [CategoryItem] = []
        var ownedDirs = Set<String>()

        // --- Homebrew (top-level formulae via `brew leaves`, plus casks) ---
        if let brewPath = locateBinary("brew", in: dirs) {
            let prefix = runCommandCapture(brewPath, ["--prefix"]) ?? "/opt/homebrew"
            let cellar = runCommandCapture(brewPath, ["--cellar"]) ?? "\(prefix)/Cellar"
            let caskroom = "\(prefix)/Caskroom"
            let appMap = appSizeMap()
            var groups: [CategoryItem] = []

            if let out = runCommandCapture(brewPath, ["leaves"]) {
                let items = trimLines(out).map { name -> CategoryItem in
                    let keg = (cellar as NSString).appendingPathComponent(name)
                    return leaf(name, calculateDirectorySize(at: keg, isDirectory: true), finderPath: keg)
                }.sorted { $0.sizeBytes > $1.sizeBytes }
                if !items.isEmpty {
                    groups.append(displayParent(name: "Formulae", label: "Formulae (\(items.count))", icon: "shippingbox.fill", color: .orange, children: items, finderPath: cellar))
                }
            }
            if let out = runCommandCapture(brewPath, ["list", "--cask"]) {
                let items = trimLines(out).map { name -> CategoryItem in
                    let caskPath = (caskroom as NSString).appendingPathComponent(name)
                    var size = calculateDirectorySize(at: caskPath, isDirectory: true)
                    let appPath = appMap[normalizeString(name)]
                    if let appPath = appPath {
                        size += calculateDirectorySize(at: appPath, isDirectory: true)
                    }
                    return leaf(name, size, finderPath: appPath ?? caskPath)
                }.sorted { $0.sizeBytes > $1.sizeBytes }
                if !items.isEmpty {
                    groups.append(displayParent(name: "Casks", label: "Casks (\(items.count))", icon: "shippingbox.fill", color: .orange, children: items, finderPath: caskroom))
                }
            }
            ownedDirs.insert((brewPath as NSString).deletingLastPathComponent)
            if dirs.contains("/usr/local/bin") { ownedDirs.insert("/usr/local/bin") }

            if !groups.isEmpty {
                toolNodes.append(displayParent(name: "Homebrew", label: "Homebrew", icon: "cup.and.saucer.fill", color: .orange, children: groups, finderPath: prefix))
            }
        }

        // --- Node.js (enumerate every installation: nvm/fnm/volta/asdf/nodenv/n, Homebrew, /usr/local, npmrc/env prefix, active PATH) ---
        if let nodeNode = scanNodeInstalls(dirs: dirs, ownedDirs: &ownedDirs) {
            toolNodes.append(nodeNode)
        }

        // --- pnpm (global) ---
        if let pnpmPath = locateBinary("pnpm", in: dirs) {
            var root: String?
            var pkgs: [(String, Int64)] = []
            if let r = runCommandCapture(pnpmPath, ["root", "-g"]) {
                root = r
                pkgs = sizedPackages(in: r)
            }
            if let gbin = runCommandCapture(pnpmPath, ["config", "get", "global-bin-dir"]), !gbin.isEmpty {
                ownedDirs.insert(gbin)
            }
            if !pkgs.isEmpty, let r = root {
                let children = pkgs.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (r as NSString).appendingPathComponent($0.0)) }
                toolNodes.append(displayParent(name: "pnpm", label: "pnpm (global)", icon: "shippingbox.fill", color: .teal, children: children, finderPath: r))
            }
        }

        // --- Yarn (global) ---
        if let yarnPath = locateBinary("yarn", in: dirs) {
            var root: String?
            var pkgs: [(String, Int64)] = []
            if let gdir = runCommandCapture(yarnPath, ["global", "dir"]) {
                let r = (gdir as NSString).appendingPathComponent("node_modules")
                root = r
                pkgs = sizedPackages(in: r)
            }
            if let gbin = runCommandCapture(yarnPath, ["global", "bin"]) {
                ownedDirs.insert(gbin)
            }
            if !pkgs.isEmpty, let r = root {
                let children = pkgs.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (r as NSString).appendingPathComponent($0.0)) }
                toolNodes.append(displayParent(name: "Yarn", label: "Yarn (global)", icon: "shippingbox.fill", color: .blue, children: children, finderPath: r))
            }
        }

        // --- Cargo (user-installed crates; size = sum of the binaries each crate installed) ---
        if let cargoPath = locateBinary("cargo", in: dirs) {
            let cargoBin = (cargoPath as NSString).deletingLastPathComponent
            var crates: [(String, Int64)] = []
            if let out = runCommandCapture(cargoPath, ["install", "--list"]) {
                let headerRegex = try? NSRegularExpression(pattern: "^(\\S+) v[\\d.]+:")
                var currentName: String?
                var currentBins: [String] = []
                func flush() {
                    guard let n = currentName else { return }
                    var size: Int64 = 0
                    for b in currentBins {
                        size += calculateDirectorySize(at: (cargoBin as NSString).appendingPathComponent(b), isDirectory: false)
                    }
                    crates.append((n, size))
                    currentName = nil
                    currentBins = []
                }
                for raw in out.split(separator: "\n") {
                    let line = String(raw)
                    let range = NSRange(line.startIndex..., in: line)
                    if let m = headerRegex?.firstMatch(in: line, options: [], range: range),
                       let r = Range(m.range(at: 1), in: line) {
                        flush()
                        currentName = String(line[r])
                    } else if line.first?.isWhitespace == true {
                        let bin = line.trimmingCharacters(in: .whitespaces)
                        if !bin.isEmpty { currentBins.append(bin) }
                    }
                }
                flush()
            }
            ownedDirs.insert(cargoBin)
            if !crates.isEmpty {
                let children = crates.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: cargoBin) }
                toolNodes.append(displayParent(name: "Cargo", label: "Cargo", icon: "hammer.fill", color: .orange, children: children, finderPath: cargoBin))
            }
        }

        // --- Ruby gems (size each installed gem dir across all GEM PATHS) ---
        if let gemPath = locateBinary("gem", in: dirs) {
            let gpaths = gemPaths(gemPath: gemPath)
            var gemSizes: [String: Int64] = [:]
            var gemLoc: [String: String] = [:]
            for gp in gpaths {
                let gemsDir = (gp as NSString).appendingPathComponent("gems")
                guard let entries = try? fm.contentsOfDirectory(atPath: gemsDir) else { continue }
                for entry in entries {
                    guard let name = gemName(from: entry) else { continue }
                    let dir = (gemsDir as NSString).appendingPathComponent(entry)
                    let size = calculateDirectorySize(at: dir, isDirectory: true)
                    gemSizes[name, default: 0] += size
                    if gemLoc[name] == nil { gemLoc[name] = dir }
                }
            }
            if !gemSizes.isEmpty {
                let children = gemSizes.map { leaf($0.key, $0.value, finderPath: gemLoc[$0.key]) }.sorted { $0.sizeBytes > $1.sizeBytes }
                toolNodes.append(displayParent(name: "Ruby Gems", label: "Ruby Gems", icon: "diamond.fill", color: .red, children: children, finderPath: gpaths.first))
            }
        }

        // --- Go (GOPATH/bin tools) ---
        if let goPath = locateBinary("go", in: dirs) {
            var tools: [(String, Int64)] = []
            var goBin: String?
            if let gopath = runCommandCapture(goPath, ["env", "GOPATH"]), !gopath.isEmpty {
                let resolved = gopath.hasPrefix("~/")
                    ? (home as NSString).appendingPathComponent(String(gopath.dropFirst(2)))
                    : gopath
                let bin = (resolved as NSString).appendingPathComponent("bin")
                for name in binariesInDir(bin) {
                    let size = calculateDirectorySize(at: (bin as NSString).appendingPathComponent(name), isDirectory: false)
                    tools.append((name, size))
                }
                ownedDirs.insert(bin)
                goBin = bin
            }
            if !tools.isEmpty, let bin = goBin {
                let children = tools.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (bin as NSString).appendingPathComponent($0.0)) }
                toolNodes.append(displayParent(name: "Go", label: "Go", icon: "shippingbox.fill", color: .cyan, children: children, finderPath: bin))
            }
        }

        // --- Pipx ---
        if let pipxPath = locateBinary("pipx", in: dirs) {
            var pipxHome = ""
            if let env = runCommandCapture(pipxPath, ["environment"]) {
                for raw in env.split(separator: "\n") {
                    let s = String(raw).trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("PIPX_HOME"), let eq = s.firstIndex(of: "=") {
                        var val = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                        val = val.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                        pipxHome = val
                    }
                }
            }
            if pipxHome.isEmpty {
                pipxHome = (home as NSString).appendingPathComponent(".local/pipx")
            }
            let venvsDir = (pipxHome as NSString).appendingPathComponent("venvs")
            var apps: [(String, Int64)] = []
            if let out = runCommandCapture(pipxPath, ["list", "--short"]) {
                for name in trimLines(out) {
                    let size = calculateDirectorySize(at: (venvsDir as NSString).appendingPathComponent(name), isDirectory: true)
                    apps.append((name, size))
                }
            }
            if !apps.isEmpty {
                let children = apps.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (venvsDir as NSString).appendingPathComponent($0.0)) }
                toolNodes.append(displayParent(name: "Pipx", label: "Pipx", icon: "shippingbox.fill", color: .indigo, children: children, finderPath: venvsDir))
            }
        }

        // --- Other non-system PATH tools (dirs not owned by a manager above) ---
        var otherNodes: [CategoryItem] = []
        for dir in dirs where !ownedDirs.contains(dir) {
            var bins: [(String, Int64)] = []
            for name in binariesInDir(dir) {
                let size = calculateDirectorySize(at: (dir as NSString).appendingPathComponent(name), isDirectory: false)
                bins.append((name, size))
            }
            if bins.isEmpty { continue }
            let display = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            let children = bins.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (dir as NSString).appendingPathComponent($0.0)) }
            otherNodes.append(displayParent(name: dir, label: display, icon: "folder.fill", color: .blue, children: children, finderPath: dir))
        }
        if !otherNodes.isEmpty {
            otherNodes.sort { $0.sizeBytes > $1.sizeBytes }
            toolNodes.append(displayParent(name: "Other PATH tools", label: "Other PATH tools", icon: "folder.fill", color: .blue, children: otherNodes))
        }

        // Drop tool nodes whose on-disk location is already listed in the Home Directory
        // section (e.g. ~/.cargo, ~/go, ~/.nvm) so the same data isn't shown twice.
        let coveredPaths = homeDirectoryEntryPaths()
        let filteredToolNodes = filterHomeCoveredNodes(toolNodes, coveredPaths: coveredPaths)
        return displayParent(name: "Installed Tools", label: "Installed Tools", icon: "terminal.fill", color: .primary, note: "Read Only", children: filteredToolNodes)
    }

    // Enumerate every non-system entry (file or folder, hidden or visible) directly under the
    // home directory -- especially the dot-prefixed tool/data folders such as .ollama, .cargo,
    // .gradle. Display-only: each row reveals its location in Finder via the magnifying glass;
    // nothing here is ever cleaned. Docker is added explicitly because its ~60GB VM disk lives
    // under ~/Library/Containers (nested under Library, so a home-root scan would miss it).
    private func scanHomeDirectory() -> CategoryItem? {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: home) else { return nil }

        var childItems: [CategoryItem] = []

        // Docker's bulk data is nested under ~/Library/Containers, not the home root, so the
        // enumeration below can't see it. Surface it as a special entry when present.
        let dockerPath = (home as NSString).appendingPathComponent("Library/Containers/com.docker.docker")
        var dockerIsDir: ObjCBool = false
        if fm.fileExists(atPath: dockerPath, isDirectory: &dockerIsDir), dockerIsDir.boolValue {
            let bytes = calculateDirectorySize(at: dockerPath, isDirectory: true)
            if bytes > 0 {
                childItems.append(displayItem(name: "Docker", label: "Docker", icon: "cube.fill", color: .blue, sizeBytes: bytes, finderPath: dockerPath, description: "Docker Data"))
            }
        }

        for entry in entries {
            let lowerEntry = entry.lowercased()
            if Self.homeSystemEntries.contains(lowerEntry) { continue }
            // iCloud Drive's local archive ("iCloud云盘（归档）" / "iCloud Drive") is macOS-managed
            if lowerEntry.hasPrefix("icloud") { continue }

            let fullPath = (home as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &entryIsDir) else { continue }

            let bytes = calculateDirectorySize(at: fullPath, isDirectory: entryIsDir.boolValue)
            var icon: String
            var color: Color
            
            if let custom = Self.homeEntryIcons[lowerEntry] {
                icon = custom.0
                color = custom.1
            } else if entryIsDir.boolValue {
                icon = entry.hasPrefix(".") ? "folder.fill" : "folder"
                color = .blue
            } else {
                icon = "doc"
                color = .secondary
            }
            
            childItems.append(displayItem(name: entry, label: "~/\(entry)", icon: icon, color: color, sizeBytes: bytes, finderPath: fullPath, description: Self.homeEntryDescriptions[lowerEntry].map { LocalizedStringKey($0) }))
        }

        guard !childItems.isEmpty else { return nil }
        childItems.sort { $0.sizeBytes > $1.sizeBytes }

        return displayParent(name: "Home Directory", label: "Home Directory", icon: "house.fill", color: .primary, note: "Non-system Items", children: childItems)
    }

    // Mirror of scanAppLeftovers, but lists Application Support folders that belong to
    // INSTALLED apps (so the user can browse/open them). Display-only: no deletion.
    private func scanInstalledAppData(basePath: String) -> CategoryItem? {
        let expandedBasePath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default
        guard let subfolders = try? fileManager.contentsOfDirectory(atPath: expandedBasePath) else {
            return nil
        }

        let installedApps = fetchInstalledAppIdentifiers()

        var childItems: [CategoryItem] = []

        for folder in subfolders {
            if folder.hasPrefix(".") || folder.hasSuffix("_Lock") {
                continue
            }

            let lowerFolder = folder.lowercased()
            let normalizedFolder = normalizeString(folder)

            // Skip macOS system folders
            if isSystemOwnedAppSupportFolder(folder, lowerFolder: lowerFolder) {
                continue
            }

            // KEEP only folders that correspond to a currently installed application
            guard folderMatchesInstalledApp(folder, lowerFolder: lowerFolder, normalizedFolder: normalizedFolder, installedApps: installedApps) else {
                continue
            }

            let fullPath = (expandedBasePath as NSString).appendingPathComponent(folder)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            let sizeBytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            // Display-only browsing: focus on folders taking meaningful space (> 50 MB)
            guard sizeBytes > 50_000_000 else { continue }

            let displayPath = "\(basePath)/\(folder)"
            childItems.append(displayItem(name: folder, label: displayPath, icon: "folder.fill", color: .blue, sizeBytes: sizeBytes, finderPath: fullPath))
        }

        guard !childItems.isEmpty else { return nil }
        childItems.sort { $0.sizeBytes > $1.sizeBytes }

        return displayParent(name: "Installed App Data", label: basePath, icon: "folder.fill", color: .blue, note: "App Data", children: childItems, finderPath: expandedBasePath)
    }


    func calculateDirectorySize(at path: String, isDirectory: Bool) -> Int64 {
        let url = URL(fileURLWithPath: path)
        if !isDirectory {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                return Int64(size)
            }
            return 0
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               let isDir = values.isDirectory, !isDir,
               let size = values.fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

}
