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

struct ContentView: View {
    // Disk Space State
    @State private var totalBytes: Int64 = 0
    @State private var freeBytes: Int64 = 0
    @State private var usedBytes: Int64 = 0
    @State private var isScanning: Bool = false

    @State private var categories: [CategoryItem] = []

    // Outline table column sort order (click headers to sort)
    @State private var sortOrder: [KeyPathComparator<CategoryItem>] = []

    var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(Double(usedBytes) / Double(totalBytes) * 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Main Content: Cleanable Directory Outline Table
            cleanListView

            Divider()

            // MARK: - Bottom Status Bar: Disk Usage Data
            bottomStatusBar
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
                HStack(alignment: .center, spacing: 4) {
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
                HStack(spacing: 6) {
                    Button {
                        openInFinder(pathDescription: item.pathDescription)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    if case .none = item.rule.cleanType {
                        EmptyView()
                    } else {
                        Button("Clean") {
                            performClean(item: item)
                        }
                        .disabled(isScanning)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            .width(min: 110, ideal: 130, max: 170)
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

    // MARK: - Bottom Status Bar
    private var bottomStatusBar: some View {
        HStack(spacing: 14) {
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

            Divider().frame(height: 14)

            Label("Used \(formatBytes(usedBytes))", systemImage: "circle.fill")
                .foregroundColor(.gray)
                .font(.system(size: 12))

            Label("Free \(formatBytes(freeBytes))", systemImage: "circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))

            Label("Total \(formatBytes(totalBytes))", systemImage: "internaldrive")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            Spacer()

            if isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
                } else if rule.isDynamicLeftoversRule {
                    let leftoverItems = self.scanAppLeftovers(basePath: rule.pathDescription)
                    foundCategories.append(contentsOf: leftoverItems)
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
                        cleanType: .deleteDirectory
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
            cleanType: .deleteDirectory
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

    // Clean specified category
    private func performClean(item: CategoryItem) {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
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

            DispatchQueue.main.async {
                self.performScan()
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

