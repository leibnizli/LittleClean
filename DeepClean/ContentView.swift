import SwiftUI

struct CategoryItem: Identifiable {
    let id = UUID()
    let name: String
    let pathDescription: String
    let iconName: String
    let iconColor: Color
    var sizeBytes: Int64
    var sizeString: String
    let rule: CleanRule
    var children: [CategoryItem]? = nil
    var isSelected: Bool = true
    // Read-only informational node: no checkbox, never cleaned (Finder reveal via finderPath)
    var isDisplayOnly: Bool = false
    // Real filesystem location to reveal in Finder (display-only nodes use a label as pathDescription)
    var finderPath: String? = nil
    // Override label shown in the Path column (used to show ancestor context in search results)
    var displayPath: String? = nil
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
    // Token used to invalidate stale "Installed Tools" background loads across rescans
    @State private var toolsLoadToken: Int = 0

    @State private var categories: [CategoryItem] = []

    // Outline table column sort order (click headers to sort); default: size descending
    @State private var sortOrder: [KeyPathComparator<CategoryItem>] = [KeyPathComparator(\.sizeBytes, order: .reverse)]

    // Checkbox multi-selection of cleanable items
    @State private var selectedIDs: Set<UUID> = []

    // Search query (filters the table to matching leaves)
    @State private var searchText: String = ""

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
        .searchable(text: $searchText, prompt: "Search")
    }

    // MARK: - Cleanable Directory Outline Table
    private var cleanListView: some View {
        Table(displayedCategories, children: \.children, sortOrder: $sortOrder) {
            TableColumn("Path", value: \.pathDescription) { item in
                HStack(alignment: .center, spacing: 6) {
                    if item.isDisplayOnly {
                        Image(systemName: item.iconName)
                            .foregroundColor(item.iconColor)
                            .frame(width: 16)
                    } else {
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
                    }

                    Text(item.displayPath ?? item.pathDescription)
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
                let target = item.isDisplayOnly ? item.finderPath : item.pathDescription
                if let target = target, !target.isEmpty {
                    Button {
                        openInFinder(pathDescription: target)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .width(min: 40, ideal: 50, max: 60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    // Items shown in the table: when searching, a flat list of matching leaves (each labeled
    // with its ancestor chain so matches are always visible); otherwise the full hierarchy.
    // Then sorted by the current column sort order.
    private var displayedCategories: [CategoryItem] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? categories
            : flatFilteredLeaves(categories, query: searchText)
        var result = base.sorted(using: sortOrder)
        for index in result.indices {
            result[index].children?.sort(using: sortOrder)
        }
        return result
    }

    // Flatten the tree to leaf nodes matching `query`, each relabeled with its ancestor chain.
    private func flatFilteredLeaves(_ items: [CategoryItem], query: String) -> [CategoryItem] {
        let q = query.lowercased()
        var result: [CategoryItem] = []
        func walk(_ items: [CategoryItem], ancestors: [String]) {
            for item in items {
                if let children = item.children, !children.isEmpty {
                    walk(children, ancestors: ancestors + [item.pathDescription])
                } else {
                    let context = (ancestors + [item.pathDescription]).joined(separator: " / ")
                    let hay = (item.name + " " + item.pathDescription + " " + context + " " + (item.rule.note ?? "")).lowercased()
                    if hay.contains(q) {
                        var copy = item
                        copy.displayPath = context
                        copy.children = nil
                        result.append(copy)
                    }
                }
            }
        }
        walk(items, ancestors: [])
        return result
    }

    // MARK: - Top Status Bar
    private var topStatusBar: some View {
        HStack(spacing: 14) {

            Label("\(formatBytes(usedBytes)) / \(formatBytes(totalBytes))", systemImage: "internaldrive")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text("Free \(formatBytes(freeBytes))")
                .foregroundColor(.green)
                .font(.system(size: 12))
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
                // Phase 2: load the informational "Installed Tools" section in the background
                self.loadInstalledToolsAsync()
            }
        }
    }

    // Phase 2 of the scan: build the read-only "Installed Tools" tree off the main thread
    // and merge it in when ready. A token invalidates stale loads across rescans.
    private func loadInstalledToolsAsync() {
        toolsLoadToken += 1
        let token = toolsLoadToken
        DispatchQueue.global(qos: .utility).async {
            let toolsItem = self.scanInstalledTools()
            DispatchQueue.main.async {
                guard token == self.toolsLoadToken, !self.isScanning else { return }
                // Avoid duplicates if a load somehow lands twice
                guard !self.categories.contains(where: { $0.isDisplayOnly && $0.name == "Installed Tools" }) else { return }
                if toolsItem.children?.isEmpty == false {
                    self.categories.append(toolsItem)
                }
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
    private func displayItem(name: String, label: String, icon: String, color: Color, note: String? = nil, children: [CategoryItem]? = nil, sizeBytes: Int64 = 0, finderPath: String? = nil) -> CategoryItem {
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
            finderPath: finderPath
        )
    }

    // Display parent whose size is the sum of its children's sizes.
    private func displayParent(name: String, label: String, icon: String, color: Color, note: String? = nil, children: [CategoryItem], finderPath: String? = nil) -> CategoryItem {
        let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return displayItem(name: name, label: label, icon: icon, color: color, note: note, children: children, sizeBytes: total, finderPath: finderPath)
    }

    // A read-only leaf module with an optional on-disk size and Finder location.
    private func leaf(_ name: String, _ size: Int64 = 0, finderPath: String? = nil) -> CategoryItem {
        displayItem(name: name, label: name, icon: "circle.fill", color: .secondary, sizeBytes: size, finderPath: finderPath)
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
                installNodes.append(displayItem(name: label, label: displayLabel, icon: "shippingbox.fill", color: .green, note: "no global packages", finderPath: nm.isEmpty ? nil : nm))
            } else {
                let children = pkgs.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: (nm as NSString).appendingPathComponent($0.0)) }
                installNodes.append(displayParent(name: label, label: displayLabel, icon: "shippingbox.fill", color: .green, children: children, finderPath: nm))
            }
        }

        return displayParent(name: "Node.js", label: "Node.js", icon: "shippingbox.fill", color: .green, children: installNodes)
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
            otherNodes.append(displayParent(name: dir, label: display, icon: "folder.fill", color: .gray, children: children, finderPath: dir))
        }
        if !otherNodes.isEmpty {
            otherNodes.sort { $0.sizeBytes > $1.sizeBytes }
            toolNodes.append(displayParent(name: "Other PATH tools", label: "Other PATH tools", icon: "folder.fill", color: .secondary, children: otherNodes))
        }

        return displayParent(name: "Installed Tools", label: "Installed Tools", icon: "terminal.fill", color: .secondary, note: "informational only", children: toolNodes)
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

    // Clean every selected cleanable item; the user triggers a rescan manually.
    // After cleaning, the affected leaves are re-measured (now empty/gone -> 0) and
    // parent totals recomputed, so the table reflects the deletion without a full rescan.
    private func performCleanSelected() {
        let toClean = collectCleanableSelected(from: categories)
        guard !toClean.isEmpty else { return }
        let cleanedIDs = Set(toClean.map { $0.id })
        let snapshot = categories
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            for item in toClean {
                self.cleanItem(item)
            }
            let updated = self.rebuildRemeasuringCleanedLeaves(in: snapshot, cleanedIDs: cleanedIDs)
            DispatchQueue.main.async {
                self.categories = updated
                self.isCleaning = false
                self.selectedIDs = []
                self.loadRealDiskSpace()
            }
        }
    }

    // Return a copy of the tree where cleaned leaves are re-measured (0 once deleted)
    // and every parent's size is recomputed from its children.
    private func rebuildRemeasuringCleanedLeaves(in items: [CategoryItem], cleanedIDs: Set<UUID>) -> [CategoryItem] {
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
                var isDir: ObjCBool = false
                let newSize: Int64 = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
                    ? calculateDirectorySize(at: expanded, isDirectory: isDir.boolValue)
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
        if bytes == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.countStyle = .file
        var result = formatter.string(fromByteCount: bytes)
        if result == "Zero KB" {
            result = "0 KB"
        }
        return result
    }

    // Open a directory in Finder, or reveal a file / .app bundle (without launching it).
    private func openInFinder(pathDescription: String) {
        let expandedPath = NSString(string: pathDescription).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir) else { return }
        if expandedPath.hasSuffix(".app") || !isDir.boolValue {
            // Reveal files / app bundles in Finder instead of launching them
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    ContentView()
}

