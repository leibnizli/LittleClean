import SwiftUI

struct CategoryItem: Identifiable {
    let id = UUID()
    let name: String
    let pathDescription: String
    let iconName: String
    let iconColor: Color
    let sizeBytes: Int64
    let sizeString: String
    let rule: CleanRule
    var children: [CategoryItem]? = nil
    var isSelected: Bool = true
}

private enum SelectionState {
    case checked, unchecked, mixed
    var symbolName: String {
        switch self {
        case .checked: return "checkmark.square.fill"
        case .unchecked: return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}

struct ContentView: View {
    // Disk Space State
    @State private var totalBytes: Int64 = 0
    @State private var freeBytes: Int64 = 0
    @State private var usedBytes: Int64 = 0
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false

    @State private var categories: [CategoryItem] = []

    // Outline table column sort order (click headers to sort)
    @State private var sortOrder: [KeyPathComparator<CategoryItem>] = []

    // Checkbox multi-selection of cleanable items
    @State private var selectedIDs: Set<UUID> = []

    var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(Double(usedBytes) / Double(totalBytes) * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Status Bar: Disk Usage Data
            topStatusBar

            Divider()

            // MARK: - Main Content: Cleanable Directory Outline Table
            cleanListView

            Divider()

            // MARK: - Bottom Action Bar: Selection + Clean
            bottomActionBar
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            performScan()
        }
    }

    // MARK: - Cleanable Directory Outline Table
    private var cleanListView: some View {
        Table(sortedCategories, children: \.children, sortOrder: $sortOrder) {
            TableColumn("Path", value: \.pathDescription) { item in
                HStack(alignment: .center, spacing: 6) {
                    let state = selectionState(for: item)
                    let enabled = isCleanable(item)
                    Button {
                        toggleSelection(item)
                    } label: {
                        Image(systemName: state.symbolName)
                            .foregroundColor(enabled ? Color(NSColor.controlAccentColor) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)

                    Text(item.pathDescription)
                        .font(.system(size: 13))
                    if let note = item.rule.note {
                        Text("(\(note))")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                    }
                }
            }

            TableColumn("Size", value: \.sizeBytes) { item in
                Text(item.sizeString)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .width(min: 90, ideal: 110, max: 150)

            TableColumn("") { item in
                Button {
                    openInFinder(pathDescription: item.pathDescription)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .width(min: 40, ideal: 50, max: 60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    // Apply current sort order to top-level items and their children
    private var sortedCategories: [CategoryItem] {
        var result = categories.sorted(using: sortOrder)
        for index in result.indices {
            result[index].children?.sort(using: sortOrder)
        }
        return result
    }

    // MARK: - Top Status Bar
    private var topStatusBar: some View {
        HStack(spacing: 14) {

            Label("\(formatBytes(usedBytes)) / \(formatBytes(totalBytes))", systemImage: "internaldrive")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            Label("Free \(formatBytes(freeBytes))", systemImage: "circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
            Divider().frame(height: 14)
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.green)
                        
                        Capsule()
                            .fill(Color.gray)
                            .frame(width: max(0, geometry.size.width * CGFloat(usedPercentage) / 100))
                    }
                }
                .frame(width: 150, height: 6)
            }
            Spacer()

            if isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if isCleaning {
                ProgressView()
                    .controlSize(.small)
                Text("Cleaning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    performScan()
                } label: {
                    Text("Scan")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Bottom Action Bar: Selection + Clean
    private var bottomActionBar: some View {
        HStack(spacing: 14) {
            Button {
                performCleanSelected()
            } label: {
                Text("Clean")
            }
            .disabled(selectedIDs.isEmpty || isScanning || isCleaning)
            .buttonStyle(.borderedProminent)

            Spacer()

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // Scan configured paths and display existing items with calculated size
    private func performScan() {
        isScanning = true
        loadRealDiskSpace()

        DispatchQueue.global(qos: .userInitiated).async {
            var foundCategories: [CategoryItem] = []
            let fileManager = FileManager.default

            for rule in CleanConfig.defaultRules {
                let expandedPath = NSString(string: rule.pathDescription).expandingTildeInPath
                var isDirectory: ObjCBool = false

                if rule.isDynamicSimulatorRule {
                    let simItems = self.scanSimulatorVersions(basePath: rule.pathDescription)
                    foundCategories.append(contentsOf: simItems)
                } else if rule.isDynamicUnavailableSimulatorRule {
                    let unavailItems = self.scanUnavailableSimulators(basePath: rule.pathDescription)
                    foundCategories.append(contentsOf: unavailItems)
                } else if rule.isDynamicLeftoversRule {
                    let leftoverItems = self.scanAppLeftovers(basePath: rule.pathDescription)
                    foundCategories.append(contentsOf: leftoverItems)
                } else if rule.isDynamicHomeCacheRule {
                    let cacheItems = self.scanHomeCaches(basePath: rule.pathDescription)
                    foundCategories.append(contentsOf: cacheItems)
                } else if rule.isDynamicHomeLeftoversRule {
                    let homeItems = self.scanHomeLeftovers(basePath: rule.pathDescription)
                    foundCategories.append(contentsOf: homeItems)
                } else if fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
                    let totalBytes = calculateDirectorySize(at: expandedPath, isDirectory: isDirectory.boolValue)
                    let sizeStr = formatBytes(totalBytes)

                    let item = CategoryItem(
                        name: rule.name,
                        pathDescription: rule.pathDescription,
                        iconName: rule.iconName,
                        iconColor: rule.iconColor,
                        sizeBytes: totalBytes,
                        sizeString: sizeStr,
                        rule: rule
                    )
                    foundCategories.append(item)
                }
            }

            DispatchQueue.main.async {
                self.categories = foundCategories
                self.selectedIDs = []
                self.isScanning = false
            }
        }
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

        let sortedVersions = versionGroups.keys.sorted()
        let versionsSummary = sortedVersions.joined(separator: ", ")
        let totalBytes = versionGroups.values.reduce(0) { $0 + $1.bytes }

        let reminderRule = CleanRule(
            name: "Multiple Simulator Versions",
            pathDescription: basePath,
            iconName: "exclamationmark.triangle.fill",
            iconColor: .orange,
            cleanType: .none,
            note: "Detected \(versionGroups.keys.count) versions (\(versionsSummary)). Please manage or delete unused versions if necessary."
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

        for (runtime, devices) in devicesByRuntime {
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
                let runtimeName = parseRuntimeName(runtime)
                let displayPath = "\(basePath)/\(udid)"

                let rule = CleanRule(
                    name: deviceName,
                    pathDescription: displayPath,
                    iconName: "iphone.slash",
                    iconColor: .red,
                    cleanType: .runCommand(executable: "/usr/bin/xcrun", args: ["simctl", "delete", udid]),
                    note: "\(deviceName) - \(runtimeName)"
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
            note: "Simulator devices whose runtime is no longer installed"
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

    // Fetch all currently installed application names and bundle identifiers across system application directories
    private func normalizeString(_ str: String) -> String {
        return str.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private func isBinaryInPATH(_ name: String) -> Bool {
        let cleanName = name.lowercased()
        let pathDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".cargo/bin"),
            (NSHomeDirectory() as NSString).appendingPathComponent("go/bin")
        ]
        let fileManager = FileManager.default
        for dir in pathDirs {
            let fullPath = (dir as NSString).appendingPathComponent(cleanName)
            if fileManager.fileExists(atPath: fullPath) {
                return true
            }
        }
        return false
    }

    // Fetch all currently installed application names and bundle identifiers across system application directories
    private func fetchInstalledAppIdentifiers() -> Set<String> {
        var identifiers = Set<String>()
        let appDirs = [
            "/Applications",
            "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]

        let fileManager = FileManager.default

        for dir in appDirs {
            guard let items = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                if item.hasSuffix(".app") {
                    let appBundleURL = URL(fileURLWithPath: dir).appendingPathComponent(item)

                    // 1. Finder Display Name (e.g., "微信开发者工具")
                    let finderDisplayName = fileManager.displayName(atPath: appBundleURL.path)
                    let cleanFinderName = (finderDisplayName as NSString).deletingPathExtension.lowercased()
                    identifiers.insert(cleanFinderName)
                    identifiers.insert(normalizeString(cleanFinderName))

                    // 2. Disk App Name (e.g., "wechatwebdevtools")
                    let appName = (item as NSString).deletingPathExtension.lowercased()
                    identifiers.insert(appName)
                    identifiers.insert(normalizeString(appName))

                    // 3. Info.plist
                    let infoPlistURL = appBundleURL.appendingPathComponent("Contents/Info.plist")
                    if let data = try? Data(contentsOf: infoPlistURL),
                       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                        if let bundleID = plist["CFBundleIdentifier"] as? String {
                            let bLower = bundleID.lowercased()
                            identifiers.insert(bLower)
                            identifiers.insert(normalizeString(bLower))
                            let bundleLast = (bundleID as NSString).pathExtension.lowercased()
                            if !bundleLast.isEmpty {
                                identifiers.insert(bundleLast)
                                identifiers.insert(normalizeString(bundleLast))
                            }
                        }
                        if let bundleName = plist["CFBundleName"] as? String {
                            let bName = bundleName.lowercased()
                            identifiers.insert(bName)
                            identifiers.insert(normalizeString(bName))
                        }
                        if let displayName = plist["CFBundleDisplayName"] as? String {
                            let dName = displayName.lowercased()
                            identifiers.insert(dName)
                            identifiers.insert(normalizeString(dName))
                        }
                    }

                    // 4. Scan all localized InfoPlist.strings (e.g., zh_CN.lproj, zh-Hans.lproj)
                    let resourcesURL = appBundleURL.appendingPathComponent("Contents/Resources")
                    if let resContents = try? fileManager.contentsOfDirectory(atPath: resourcesURL.path) {
                        for resItem in resContents {
                            if resItem.hasSuffix(".lproj") {
                                let stringsURL = resourcesURL.appendingPathComponent(resItem).appendingPathComponent("InfoPlist.strings")
                                if let data = try? Data(contentsOf: stringsURL),
                                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
                                    if let dispName = plist["CFBundleDisplayName"] {
                                        let lower = dispName.lowercased()
                                        identifiers.insert(lower)
                                        identifiers.insert(normalizeString(lower))
                                    }
                                    if let bName = plist["CFBundleName"] {
                                        let lower = bName.lowercased()
                                        identifiers.insert(lower)
                                        identifiers.insert(normalizeString(lower))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return identifiers
    }

    // Dynamically scan for folders in Application Support that belong to UNINSTALLED applications
    private func scanAppLeftovers(basePath: String) -> [CategoryItem] {
        let expandedBasePath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default
        guard let subfolders = try? fileManager.contentsOfDirectory(atPath: expandedBasePath) else {
            return []
        }

        let installedApps = fetchInstalledAppIdentifiers()

        // System / macOS essential folders to skip
        let systemIgnoreList: Set<String> = [
            "addressbook", "clouddocs", "mobilesync", "dock", "safari", "apple", "com.apple.",
            "accounts", "crashreporter", "defaultappprovider", "knowledge", "quick look",
            "app store", "callhistorydb", "coresimulator", "developer", "system", "syncservices",
            "bluetooth", "preferences", "keychains", "logs", "caches"
        ]

        var childItems: [CategoryItem] = []
        var totalBytes: Int64 = 0

        for folder in subfolders {
            if folder.hasPrefix(".") || folder.hasSuffix("_Lock") {
                continue
            }

            let lowerFolder = folder.lowercased()
            let normalizedFolder = normalizeString(folder)

            // 1. Check if folder is a macOS system folder
            let isSystemFolder = systemIgnoreList.contains { sysKey in
                lowerFolder == sysKey || lowerFolder.hasPrefix(sysKey)
            }
            if isSystemFolder {
                continue
            }

            // 2. Check if folder corresponds to a CLI binary tool in PATH
            if isBinaryInPATH(folder) || isBinaryInPATH(lowerFolder) || isBinaryInPATH(normalizedFolder) {
                continue
            }

            // 3. Check if folder matches any installed application
            let isAppInstalled = installedApps.contains { appKey in
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

            // If the app is currently installed, SKIP IT (Not a leftover!)
            if isAppInstalled {
                continue
            }

            let fullPath = (expandedBasePath as NSString).appendingPathComponent(folder)
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                let sizeBytes = calculateDirectorySize(at: fullPath, isDirectory: true)
                // Only list leftover folders taking space (> 500 KB)
                if sizeBytes > 500_000 {
                    totalBytes += sizeBytes
                    let displayPath = "\(basePath)/\(folder)"
                    let childRule = CleanRule(
                        name: folder,
                        pathDescription: displayPath,
                        iconName: "folder.badge.minus",
                        iconColor: .pink,
                        cleanType: .deleteDirectoryTree
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
        }

        guard !childItems.isEmpty else { return [] }

        childItems.sort { $0.name.lowercased() < $1.name.lowercased() }

        let parentRule = CleanRule(
            name: "Uninstalled App Leftovers",
            pathDescription: basePath,
            iconName: "folder.badge.minus",
            iconColor: .pink,
            cleanType: .none,
            note: "Uninstalled Application Data"
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

    // Scan known tool cache locations under the home directory
    private func scanHomeCaches(basePath: String) -> [CategoryItem] {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default

        // Curated, safe-to-clear tool caches (contents only; folder is kept)
        let knownCaches: [(name: String, subpath: String, icon: String, color: Color)] = [
            ("XDG Cache", ".cache", "shippingbox.fill", .orange),
            ("Gradle Cache", ".gradle/caches", "hammer.fill", .purple),
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
            ("Cargo Registry Cache", ".cargo/registry", "shippingbox.fill", .orange)
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
                cleanType: .deleteDirectory
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

        guard !childItems.isEmpty else { return [] }

        let parentRule = CleanRule(
            name: "Home Tool Caches",
            pathDescription: basePath,
            iconName: "shippingbox.fill",
            iconColor: .orange,
            cleanType: .none,
            note: "Tool cache - safe to clear, will be re-downloaded"
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

    // Scan the home directory for dotfolders left behind by uninstalled apps/tools
    private func scanHomeLeftovers(basePath: String) -> [CategoryItem] {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: home) else { return [] }

        let installedApps = fetchInstalledAppIdentifiers()

        // Standard macOS user folders (non-dot, but skip defensively)
        let standardUserFolders: Set<String> = [
            "desktop", "documents", "downloads", "library", "movies", "music",
            "pictures", "public", "applications", "sites"
        ]

        // Shared / system / tool dirs handled elsewhere - never delete wholesale
        let sharedAndSystem: Set<String> = [
            ".config", ".cache", ".local", ".ssh", ".gnupg", ".aws", ".kube",
            ".docker", ".android", ".gradle", ".m2", ".ivy2", ".cargo", ".rustup",
            ".npm", ".pnpm-store", ".yarn", ".gem", ".cocoapods",
            ".bun", ".deno", ".node-gyp",
            ".ds_store", ".localized", ".cfusertextencoding", ".fseventsd",
            ".spotlight-v100", ".documentrevisions-v100", ".pkinstallsandboxmanager",
            ".vol", ".file", ".hotfiles.btree", ".trash", ".temporaryitems"
        ]

        var childItems: [CategoryItem] = []
        var totalBytes: Int64 = 0

        for entry in entries {
            // App/tool leftovers in ~ are dot-prefixed; skip regular user folders
            guard entry.hasPrefix(".") else { continue }

            let fullPath = (home as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let lower = entry.lowercased()
            let normalized = normalizeString(entry)

            if standardUserFolders.contains(lower) { continue }
            if sharedAndSystem.contains(lower) { continue }
            if isBinaryInPATH(entry) || isBinaryInPATH(lower) || isBinaryInPATH(normalized) { continue }

            // Skip folders belonging to a currently installed application
            let isInstalled = installedApps.contains { appKey in
                guard !appKey.isEmpty else { return false }
                let nApp = normalizeString(appKey)
                if lower == appKey || normalized == nApp { return true }
                if normalized.count >= 4 && nApp.count >= 4 {
                    if normalized.contains(nApp) || nApp.contains(normalized) { return true }
                }
                return false
            }
            if isInstalled { continue }

            let bytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            guard bytes > 1_000_000 else { continue } // skip trivial folders

            totalBytes += bytes
            let displayPath = "~/\(entry)"
            let rule = CleanRule(
                name: entry,
                pathDescription: displayPath,
                iconName: "folder.badge.minus",
                iconColor: .pink,
                cleanType: .deleteDirectoryTree
            )
            let item = CategoryItem(
                name: entry,
                pathDescription: displayPath,
                iconName: rule.iconName,
                iconColor: rule.iconColor,
                sizeBytes: bytes,
                sizeString: formatBytes(bytes),
                rule: rule
            )
            childItems.append(item)
        }

        guard !childItems.isEmpty else { return [] }

        childItems.sort { $0.name.lowercased() < $1.name.lowercased() }

        let parentRule = CleanRule(
            name: "Home Directory Leftovers",
            pathDescription: basePath,
            iconName: "folder.badge.minus",
            iconColor: .pink,
            cleanType: .none,
            note: "Possible uninstalled app/tool leftover"
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

    // Core deletion for a single item (runs on a background thread)
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

    // Collect selected cleanable leaf items (parents are group headers, not cleaned directly)
    private func collectCleanableSelected(from items: [CategoryItem]) -> [CategoryItem] {
        var result: [CategoryItem] = []
        for item in items {
            if let children = item.children, !children.isEmpty {
                result.append(contentsOf: collectCleanableSelected(from: children))
            } else if item.rule.cleanType != .none && selectedIDs.contains(item.id) {
                result.append(item)
            }
        }
        return result
    }

    // Clean every selected cleanable item; the user triggers a rescan manually
    private func performCleanSelected() {
        let toClean = collectCleanableSelected(from: categories)
        guard !toClean.isEmpty else { return }
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            for item in toClean {
                self.cleanItem(item)
            }
            DispatchQueue.main.async {
                self.isCleaning = false
                self.selectedIDs = []
            }
        }
    }

    // MARK: - Selection Helpers
    private func leafIDs(_ item: CategoryItem) -> Set<UUID> {
        var ids = Set<UUID>()
        if let children = item.children, !children.isEmpty {
            for child in children {
                ids.formUnion(leafIDs(child))
            }
        } else {
            ids.insert(item.id)
        }
        return ids
    }

    private func isCleanable(_ item: CategoryItem) -> Bool {
        if item.rule.cleanType != .none { return true }
        if let children = item.children {
            return children.contains { isCleanable($0) }
        }
        return false
    }

    private func selectionState(for item: CategoryItem) -> SelectionState {
        if let children = item.children, !children.isEmpty {
            let leaves = leafIDs(item)
            guard !leaves.isEmpty else { return .unchecked }
            let selected = leaves.intersection(selectedIDs).count
            if selected == 0 { return .unchecked }
            if selected == leaves.count { return .checked }
            return .mixed
        } else {
            return selectedIDs.contains(item.id) ? .checked : .unchecked
        }
    }

    private func toggleSelection(_ item: CategoryItem) {
        if let children = item.children, !children.isEmpty {
            let leaves = leafIDs(item)
            if leaves.isSubset(of: selectedIDs) {
                selectedIDs.subtract(leaves)
            } else {
                selectedIDs.formUnion(leaves)
            }
        } else {
            guard item.rule.cleanType != .none else { return }
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        }
    }

    private func calculateDirectorySize(at path: String, isDirectory: Bool) -> Int64 {
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

    // Load real macOS system disk capacity
    private func loadRealDiskSpace() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            if let total = values.volumeTotalCapacity,
               let free = values.volumeAvailableCapacityForImportantUsage {
                let totalVal = Int64(total)
                let freeVal = Int64(free)
                let usedVal = max(0, totalVal - freeVal)

                self.totalBytes = totalVal
                self.freeBytes = freeVal
                self.usedBytes = usedVal
            }
        } catch {
            print("Failed to load real disk space: \(error)")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // Open directory in Finder
    private func openInFinder(pathDescription: String) {
        let expandedPath = NSString(string: pathDescription).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ContentView()
}

