import SwiftUI

nonisolated struct CategoryScanResult: Sendable {
    let categories: [CategoryItem]
    let containerAccessDenied: Bool
}

nonisolated struct FileSystemScanner: Sendable {
    // Scan configured paths synchronously. Callers are responsible for running this off the main thread.
    func scanCategories() -> CategoryScanResult {
        var foundCategories: [CategoryItem] = []
        var containerAccessDenied = false
        let fileManager = FileManager.default

        for rule in CleanConfig.defaultRules {
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
                var allChildren: [CategoryItem] = []
                allChildren.append(contentsOf: scanHomeCaches(basePath: rule.pathDescription))
                allChildren.append(contentsOf: scanHomeLeftovers(basePath: rule.pathDescription))

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
                    parent.displayPath = "~ (Caches & Leftovers)"
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

        return CategoryScanResult(
            categories: foundCategories,
            containerAccessDenied: containerAccessDenied
        )
    }

    // Build read-only informational sections synchronously on a background queue.
    func scanDetails() -> [CategoryItem] {
        let toolsItem = scanInstalledTools()
        let homeItem = scanHomeDirectory()
        let appDataItem = scanInstalledAppData(basePath: "~/Library/Application Support")
        return ([toolsItem] + [homeItem, appDataItem].compactMap { $0 }).filter {
            guard let children = $0.children else { return false }
            return !children.isEmpty
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

    // True if a folder name (under ~/Library/Application Support or ~) corresponds to a
    // currently installed application. Shared by the leftovers and installed-app-data scans
    // so "installed" vs "leftover" can never drift apart.
    private func folderMatchesInstalledApp(_ folder: String, lowerFolder: String, normalizedFolder: String, installedApps: Set<String>) -> Bool {
        installedApps.contains { appKey in
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

                    // 1. Finder Display Name (e.g., "WeChat DevTools")
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

    // macOS system / essential folders under ~/Library/Application Support that should never
    // be listed as app data (neither leftover nor installed-app data). Shared by both scans.
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

            // 1. Check if folder is a macOS system folder
            let isSystemFolder = Self.appSupportSystemIgnoreList.contains { sysKey in
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
            let isAppInstalled = folderMatchesInstalledApp(folder, lowerFolder: lowerFolder, normalizedFolder: normalizedFolder, installedApps: installedApps)

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
            // Only list leftover containers taking space (> 500 KB), matching app leftovers.
            if sizeBytes > 500_000 {
                totalBytes += sizeBytes
                let displayPath = "\(basePath)/\(entry)"
                let childRule = CleanRule(
                    name: entry,
                    pathDescription: displayPath,
                    iconName: "shippingbox.fill",
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
            ".bun", ".deno", ".node-gyp", ".nvm", ".fnm", ".volta",
            ".asdf", ".pyenv", ".sdkman",
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
            let isInstalled = folderMatchesInstalledApp(entry, lowerFolder: lower, normalizedFolder: normalized, installedApps: installedApps)
            if isInstalled { continue }

            let bytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            guard bytes > 1_000_000 else { continue } // skip trivial folders

            totalBytes += bytes
            let displayPath = "~/\(entry)"
            let note = Self.homeEntryDescriptions[lower] ?? Self.homeEntryDescriptions[normalized]
            let rule = CleanRule(
                name: entry,
                pathDescription: displayPath,
                iconName: Self.homeEntryIcons[lower]?.0 ?? Self.homeEntryIcons[normalized]?.0 ?? "folder.badge.minus",
                iconColor: Self.homeEntryIcons[lower]?.1 ?? Self.homeEntryIcons[normalized]?.1 ?? .pink,
                cleanType: .deleteDirectoryTree,
                note: note.map { LocalizedStringKey($0) }
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

        childItems.sort { $0.name.lowercased() < $1.name.lowercased() }
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
            let isSystemFolder = Self.appSupportSystemIgnoreList.contains { sysKey in
                lowerFolder == sysKey || lowerFolder.hasPrefix(sysKey)
            }
            if isSystemFolder {
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
