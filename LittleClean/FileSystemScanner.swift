import AppKit
import Security
import SwiftUI

private nonisolated func normalizeAppIdentifier(_ str: String) -> String {
    str.lowercased()
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ".", with: "")
}

// Reference-typed, lock-protected mutable cell. Capturing a `let` instance of this in a
// @Sendable or otherwise concurrently-executing closure keeps Swift 6 strict concurrency
// satisfied for shared mutable state that cannot simply be a captured local `var`.
private nonisolated final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func with<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private nonisolated struct InstalledApplication: Sendable {
    let name: String
    let bundleIdentifier: String?
    let path: String
    let matchingNames: Set<String>
    // Bundle IDs, signing IDs, and stripped application identifiers.
    let relatedIdentifiers: Set<String>
    // Exact entitlement group IDs only -- never used for fuzzy name matching.
    let applicationGroups: Set<String>
    let managedPaths: Set<String>
    let installSource: String?
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
    private static let userApplicationRoots: [String] = [
        "/Applications",
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

    // User-facing uninstall targets only. System apps under /System are never listed.
    // Apple apps the user installed into /Applications (Xcode, iWork, Final Cut, etc.)
    // remain visible because they are legitimate uninstall targets.
    func userInstalledApplications(includingAssociations: Bool = true) -> [InstalledApplication] {
        var seenPaths = Set<String>()
        var applications: [InstalledApplication] = []

        for root in Self.userApplicationRoots {
            for bundleURL in Self.appBundles(in: root) {
                let path = bundleURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                      let application = makeApplication(
                        at: path,
                        includingAssociations: includingAssociations
                      ) else {
                    continue
                }
                applications.append(application)
            }
        }

        return applications.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // Lightweight peers for association collision checks: Info.plist only, no code-signing.
    func associationPeerApplications() -> [InstalledApplication] {
        var seenPaths = Set<String>()
        var applications: [InstalledApplication] = []

        for root in Self.userApplicationRoots {
            for bundleURL in Self.appBundles(in: root) {
                let path = bundleURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                      let application = makeApplication(
                        at: path,
                        includingAssociations: false,
                        validateRemovability: false
                      ) else {
                    continue
                }
                applications.append(application)
            }
        }
        return applications
    }

    // Resolve a single .app for Finder Services / App Intents. Rejects LittleClean itself,
    // protected system apps, and bundles the user cannot delete.
    func makeApplication(
        at appPath: String,
        includingAssociations: Bool,
        validateRemovability: Bool = true
    ) -> InstalledApplication? {
        let fileManager = FileManager.default
        let bundleURL = URL(fileURLWithPath: appPath).standardizedFileURL
        let path = bundleURL.path
        let resolvedURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolvedURL.path
        let currentAppPath = Bundle.main.bundleURL.standardizedFileURL.path
        let resourceValues = try? bundleURL.resourceValues(forKeys: [
            .isApplicationKey,
            .isSystemImmutableKey,
            .volumeIsReadOnlyKey
        ])

        guard path.lowercased().hasSuffix(".app") || resourceValues?.isApplication == true else {
            return nil
        }
        if validateRemovability {
            guard path != currentAppPath,
                  !Self.isProtectedSystemApplicationPath(resolvedPath),
                  resourceValues?.isSystemImmutable != true,
                  resourceValues?.volumeIsReadOnly != true,
                  !Self.isApplePlatformSystemApplication(at: bundleURL),
                  fileManager.isDeletableFile(atPath: path) else {
                return nil
            }
        } else if path == currentAppPath || Self.isProtectedSystemApplicationPath(resolvedPath) {
            return nil
        }

        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: infoPlistURL)).flatMap {
            try? PropertyListSerialization.propertyList(
                from: $0,
                options: [],
                format: nil
            ) as? [String: Any]
        }
        let bundleIdentifier = plist?["CFBundleIdentifier"] as? String
        guard !Self.isBlockedSystemBundleIdentifier(bundleIdentifier) else {
            return nil
        }

        let finderName = (fileManager.displayName(atPath: path) as NSString)
            .deletingPathExtension
        let diskName = bundleURL.deletingPathExtension().lastPathComponent
        let displayName = (plist?["CFBundleDisplayName"] as? String)
            ?? (plist?["CFBundleName"] as? String)
            ?? finderName

        var matchingNames = Set<String>()
        for candidate in [
            finderName,
            diskName,
            displayName,
            plist?["CFBundleName"] as? String,
            plist?["CFBundleExecutable"] as? String
        ].compactMap({ $0 }) {
            let normalized = normalizeAppIdentifier(candidate)
            if normalized.count >= 4 {
                matchingNames.insert(normalized)
            }
        }

        var relatedIdentifiers = Set<String>()
        var applicationGroups = Set<String>()
        if let bundleIdentifier {
            relatedIdentifiers.insert(bundleIdentifier.lowercased())
        }
        if includingAssociations {
            relatedIdentifiers.formUnion(Self.embeddedBundleIdentifiers(in: bundleURL))
            let signing = Self.signingFacts(at: bundleURL)
            relatedIdentifiers.formUnion(signing.identifiers)
            applicationGroups = signing.applicationGroups
        }
        let homebrewPath = Self.homebrewCaskPath(forResolvedAppPath: resolvedPath)
        let isSetapp = path.contains("/Applications/Setapp/")
            || path.contains("/Setapp/")

        return InstalledApplication(
            name: displayName,
            bundleIdentifier: bundleIdentifier,
            path: path,
            matchingNames: matchingNames,
            relatedIdentifiers: relatedIdentifiers,
            applicationGroups: applicationGroups,
            managedPaths: Set([homebrewPath].compactMap { $0 }),
            installSource: homebrewPath == nil
                ? (isSetapp ? "Setapp" : nil)
                : "Homebrew Cask"
        )
    }

    enum UninstallTargetRejection: Error, Sendable {
        case notAnApplication
        case protectedOrUndeletable
        case littleCleanItself

        var localizedReason: String {
            switch self {
            case .notAnApplication:
                String(localized: "The selection is not an application bundle.")
            case .protectedOrUndeletable:
                String(localized: "LittleClean refuses to remove itself or a protected system application.")
            case .littleCleanItself:
                String(localized: "LittleClean refuses to remove itself or a protected system application.")
            }
        }
    }

    func resolveUninstallTarget(
        at appPath: String,
        includingAssociations: Bool
    ) -> Result<InstalledApplication, UninstallTargetRejection> {
        let standardized = URL(fileURLWithPath: appPath).standardizedFileURL
        let path = standardized.path
        if path == Bundle.main.bundleURL.standardizedFileURL.path {
            return .failure(.littleCleanItself)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              path.lowercased().hasSuffix(".app") else {
            return .failure(.notAnApplication)
        }
        guard let application = makeApplication(
            at: path,
            includingAssociations: includingAssociations
        ) else {
            return .failure(.protectedOrUndeletable)
        }
        return .success(application)
    }

    private static func isProtectedSystemApplicationPath(_ resolvedPath: String) -> Bool {
        resolvedPath.hasPrefix("/System/")
            || resolvedPath.hasPrefix("/System/Cryptexes/")
            || resolvedPath.hasPrefix("/Library/Apple/")
            || resolvedPath.hasPrefix("/Library/Apple/System/")
            || resolvedPath.hasPrefix("/usr/")
    }

    // Hard-block a few OS stubs that can appear under /Applications on some setups.
    // Do not blanket-filter com.apple.* -- Xcode, iWork, and pro apps are valid targets.
    private static func isBlockedSystemBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let blocked = Set([
            "com.apple.Safari",
            "com.apple.finder",
            "com.apple.systempreferences",
            "com.apple.SoftwareUpdate",
            "com.apple.Terminal"
        ])
        return blocked.contains(bundleIdentifier)
    }

    // Apple platform code (non-zero platform identifier + Apple anchor) is OS-managed,
    // even when a copy briefly appears outside /System.
    private static func isApplePlatformSystemApplication(at appURL: URL) -> Bool {
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

    private static func embeddedBundleIdentifiers(in appURL: URL) -> Set<String> {
        let relativeRoots = [
            "Contents/PlugIns",
            "Contents/XPCServices",
            "Contents/Library/LoginItems",
            "Contents/Library/SystemExtensions"
        ]
        let bundleExtensions = Set(["app", "appex", "xpc", "systemextension"])
        let fileManager = FileManager.default
        var identifiers = Set<String>()

        for relativeRoot in relativeRoots {
            let rootURL = appURL.appendingPathComponent(relativeRoot)
            // One level is enough for standard macOS layout and avoids walking
            // each extension's own resource tree.
            guard let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ])
                guard values?.isDirectory == true,
                      values?.isSymbolicLink != true,
                      bundleExtensions.contains(child.pathExtension.lowercased()) else {
                    continue
                }
                if let identifier = Bundle(url: child)?.bundleIdentifier {
                    identifiers.insert(identifier.lowercased())
                }
            }
        }

        return identifiers
    }

    private static func signingFacts(
        at appURL: URL
    ) -> (identifiers: Set<String>, applicationGroups: Set<String>) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return ([], [])
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            return ([], [])
        }

        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        var identifiers = Set<String>()
        var applicationGroups = Set<String>()

        if let signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String,
           !signingIdentifier.isEmpty {
            identifiers.insert(signingIdentifier.lowercased())
        }

        let applicationIdentifier = (entitlements["application-identifier"] as? String)
            ?? (entitlements["com.apple.application-identifier"] as? String)
        if let applicationIdentifier, !applicationIdentifier.isEmpty {
            let lowered = applicationIdentifier.lowercased()
            identifiers.insert(lowered)
            // Strip only an exact 10-character Team ID prefix when present.
            let parts = lowered.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2,
               parts[0].count == 10,
               parts[0].allSatisfy({ $0.isNumber || ($0 >= "a" && $0 <= "z") }) {
                identifiers.insert(parts[1])
            }
        }

        if let groups = entitlements["com.apple.security.application-groups"] as? [String] {
            applicationGroups = Set(
                groups
                    .map { $0.lowercased() }
                    .filter { !$0.isEmpty }
            )
        }

        return (identifiers, applicationGroups)
    }

    private static func homebrewCaskPath(forResolvedAppPath path: String) -> String? {
        for root in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            let prefix = "\(root)/"
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            guard let caskName = remainder.split(separator: "/").first else { continue }
            return "\(root)/\(caskName)"
        }
        return nil
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

    private static let bundleIdentifierBuildVariants = [
        "debug", "beta", "alpha", "dev", "development", "staging"
    ]

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
        // Also try common Xcode build variants: a widget may keep the release id
        // (com.foo.Bar.Widget) while only com.foo.Bar.debug is installed from DerivedData.
        while components.count >= 2 {
            let base = components.joined(separator: ".")
            if isRegistered(base) {
                return true
            }
            for variant in bundleIdentifierBuildVariants {
                if components.last?.lowercased() == variant {
                    continue
                }
                if isRegistered("\(base).\(variant)") {
                    return true
                }
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
            for entry in entries {
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
        let output = LockedBox<Data>(Data())
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.with { $0 = pipe.fileHandleForReading.readDataToEndOfFile() }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return []
        }
        process.waitUntilExit()

        return String(decoding: output.with { $0 }, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .last
            .map { $0.split(separator: ":").map(String.init) } ?? []
    }
}

nonisolated struct CategoryScanResult: Sendable {
    let categories: [CategoryItem]
    let containerAccessDenied: Bool
}

nonisolated struct CategoryScanUpdate: Sendable {
    let items: [CategoryItem]
    let containerAccessDenied: Bool
}

nonisolated struct DetailScanResult: Sendable {
    let items: [CategoryItem]
    let containerAccessDenied: Bool
}

nonisolated struct FileSystemScanner: Sendable {
    // Scan configured paths synchronously. Callers are responsible for running this off the main thread.
    func scanCategories(mode: ScanMode) -> CategoryScanResult {
        if mode == .uninstallApps {
            return scanInstalledApplicationsForUninstall()
        }

        let accumulator = LockedBox<(categories: [CategoryItem], containerAccessDenied: Bool)>(
            (categories: [], containerAccessDenied: false)
        )
        scanCategoriesIncremental(mode: mode, deferSizes: false) { update in
            accumulator.with { state in
                state.categories.append(contentsOf: update.items)
                state.containerAccessDenied = state.containerAccessDenied || update.containerAccessDenied
            }
        }
        let state = accumulator.with { $0 }
        return CategoryScanResult(
            categories: state.categories,
            containerAccessDenied: state.containerAccessDenied
        )
    }

    // Parallel per-rule scan. With deferSizes, items appear quickly with pendingSizePaths
    // for later measurePendingSizes; otherwise sizes are computed inline.
    func scanCategoriesIncremental(
        mode: ScanMode,
        deferSizes: Bool,
        onUpdate: @escaping @Sendable (CategoryScanUpdate) -> Void
    ) {
        if mode == .uninstallApps {
            let result = scanInstalledApplicationsForUninstall()
            onUpdate(
                CategoryScanUpdate(
                    items: result.categories,
                    containerAccessDenied: result.containerAccessDenied
                )
            )
            return
        }

        let rules = CleanConfig.defaultRules.filter { $0.scanMode == mode }
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "littleclean.categories",
            qos: .userInitiated,
            attributes: .concurrent
        )

        for rule in rules {
            group.enter()
            queue.async {
                defer { group.leave() }
                let scanned = self.scanRule(rule, deferSizes: deferSizes)
                var items = scanned.items
                if mode == .deepAnalysis {
                    items = items.map(self.makeReadOnly)
                }
                guard !items.isEmpty || scanned.accessDenied else { return }
                onUpdate(
                    CategoryScanUpdate(
                        items: items,
                        containerAccessDenied: scanned.accessDenied
                    )
                )
            }
        }
        group.wait()
    }

    private func scanRule(
        _ rule: CleanRule,
        deferSizes: Bool
    ) -> (items: [CategoryItem], accessDenied: Bool) {
        let expandedPath = NSString(string: rule.pathDescription).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default

        if rule.isDynamicSimulatorRule {
            return (scanSimulatorVersions(basePath: rule.pathDescription), false)
        }
        if rule.isDynamicUnavailableSimulatorRule {
            return (
                scanUnavailableSimulators(basePath: rule.pathDescription, deferSizes: deferSizes),
                false
            )
        }
        if rule.isDynamicLeftoversRule {
            return (scanAppLeftovers(basePath: rule.pathDescription, deferSizes: deferSizes), false)
        }
        if rule.isDynamicContainerLeftoversRule {
            return scanContainerLeftovers(basePath: rule.pathDescription, deferSizes: deferSizes)
        }
        if rule.isDynamicExtensionLeftoversRule {
            return scanExtensionLeftovers(deferSizes: deferSizes)
        }
        if rule.isDynamicHomeCleanupRule {
            let allChildren = scanHomeCaches(basePath: rule.pathDescription, deferSizes: deferSizes)
            guard !allChildren.isEmpty else { return ([], false) }
            let totalBytes = allChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
            var parent = CategoryItem(
                name: rule.name,
                pathDescription: rule.pathDescription,
                iconName: rule.iconName,
                iconColor: rule.iconColor,
                sizeBytes: totalBytes,
                sizeString: totalBytes > 0 ? formatBytes(totalBytes) : "",
                rule: rule,
                children: allChildren
            )
            parent.displayPath = "~ (Caches)"
            return ([parent], false)
        }
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return ([], false)
        }
        if deferSizes {
            let item = CategoryItem(
                name: rule.name,
                pathDescription: rule.pathDescription,
                iconName: rule.iconName,
                iconColor: rule.iconColor,
                sizeBytes: 0,
                sizeString: "",
                rule: rule,
                pendingSizePaths: [expandedPath]
            )
            return ([item], false)
        }
        let totalBytes = calculateDirectorySize(
            at: expandedPath,
            isDirectory: isDirectory.boolValue
        )
        let item = CategoryItem(
            name: rule.name,
            pathDescription: rule.pathDescription,
            iconName: rule.iconName,
            iconColor: rule.iconColor,
            sizeBytes: totalBytes,
            sizeString: formatBytes(totalBytes),
            rule: rule
        )
        return ([item], false)
    }

    // Re-sort and re-total after lazy sizing (home caches / unavailable simulators / Chrome).
    func finalizeMeasuredCategory(_ item: CategoryItem) -> CategoryItem? {
        if item.rule.isDynamicHomeCleanupRule
            || item.rule.isDynamicUnavailableSimulatorRule
            || item.rule.isDynamicChromeCacheRule {
            let children = (item.children ?? []).compactMap { child -> CategoryItem? in
                guard let nested = child.children, !nested.isEmpty else {
                    return child
                }
                var group = child
                group.children = nested.sorted { $0.sizeBytes > $1.sizeBytes }
                let total = nested.reduce(Int64(0)) { $0 + $1.sizeBytes }
                group.sizeBytes = total
                group.sizeString = total > 0 ? formatBytes(total) : ""
                return group
            }
            guard !children.isEmpty else { return nil }
            var result = item
            result.children = children.sorted { $0.sizeBytes > $1.sizeBytes }
            let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
            result.sizeBytes = total
            result.sizeString = total > 0 ? formatBytes(total) : ""
            return result
        }
        if item.rule.isDynamicLeftoversRule
            || item.rule.isDynamicContainerLeftoversRule
            || item.rule.isDynamicExtensionLeftoversRule,
           var children = item.children, !children.isEmpty {
            children.sort { $0.sizeBytes > $1.sizeBytes }
            var result = item
            result.children = children
            let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
            result.sizeBytes = total
            result.sizeString = total > 0 ? formatBytes(total) : ""
            return result
        }
        return item
    }

    // Fast first paint: list apps with only the .app bundle as a child. Related files
    // and sizes are filled in by enrichUninstallApplications / measureUninstallApplication.
    private func scanInstalledApplicationsForUninstall() -> CategoryScanResult {
        let applications = InstalledAppIndex.shared.userInstalledApplications(
            includingAssociations: false
        )
        let items = applications.map { uninstallItem(for: $0, relatedPaths: []) }
        return CategoryScanResult(categories: items, containerAccessDenied: false)
    }

    // Resolve helpers, app groups, LaunchAgents, and Library leftovers for the listed apps.
    func enrichUninstallApplications(
        _ items: [CategoryItem]
    ) -> (items: [CategoryItem], accessDenied: Bool) {
        let applications = InstalledAppIndex.shared.userInstalledApplications(
            includingAssociations: true
        )
        let applicationsByPath = Dictionary(
            uniqueKeysWithValues: applications.map { ($0.path, $0) }
        )
        let associationResult = findAssociatedPaths(for: applications)
        let enriched = items.map { item -> CategoryItem in
            guard item.isAtomicSelection,
                  let application = applicationsByPath[item.pathDescription] else {
                return item
            }
            let relatedPaths = (associationResult.paths[application.path] ?? [])
                .union(application.managedPaths)
                .sorted()
            return uninstallItem(for: application, relatedPaths: relatedPaths)
        }
        return (enriched, associationResult.accessDenied)
    }

    nonisolated struct BackgroundUninstallPlan: Sendable {
        let item: CategoryItem
        let accessDenied: Bool
    }

    nonisolated struct BackgroundUninstallSkip: Sendable {
        let path: String
        let reason: String
    }

    // Build uninstall CategoryItems for Finder-selected .app paths, including associations.
    // Peers are indexed lightly (plist only) so Finder Services stay responsive; only the
    // selected targets pay for signing / helper-bundle association enrichment.
    func makeUninstallPlans(
        forAppPaths appPaths: [String]
    ) -> (plans: [BackgroundUninstallPlan], skipped: [BackgroundUninstallSkip]) {
        var applicationsByPath = Dictionary(
            uniqueKeysWithValues: InstalledAppIndex.shared
                .associationPeerApplications()
                .map { ($0.path, $0) }
        )
        var targets: [InstalledApplication] = []
        var skipped: [BackgroundUninstallSkip] = []
        var seenTargets = Set<String>()

        for rawPath in appPaths {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard seenTargets.insert(path).inserted else { continue }

            switch InstalledAppIndex.shared.resolveUninstallTarget(
                at: path,
                includingAssociations: true
            ) {
            case .success(let application):
                applicationsByPath[application.path] = application
                targets.append(application)
            case .failure(let rejection):
                skipped.append(BackgroundUninstallSkip(
                    path: path,
                    reason: rejection.localizedReason
                ))
            }
        }

        guard !targets.isEmpty else {
            return ([], skipped)
        }

        let associationResult = findAssociatedPaths(for: Array(applicationsByPath.values))
        let plans = targets.map { application in
            let relatedPaths = (associationResult.paths[application.path] ?? [])
                .union(application.managedPaths)
                .sorted()
            return BackgroundUninstallPlan(
                item: uninstallItem(for: application, relatedPaths: relatedPaths),
                accessDenied: associationResult.accessDenied
            )
        }
        return (plans, skipped)
    }

    func measureUninstallApplication(_ item: CategoryItem) -> CategoryItem {
        guard item.isAtomicSelection else { return item }
        let fileManager = FileManager.default
        var measuredItem = item
        let measuredChildren = (item.children ?? []).map { child -> CategoryItem in
            var measuredChild = child
            var isDirectory: ObjCBool = false
            let bytes = fileManager.fileExists(
                atPath: child.pathDescription,
                isDirectory: &isDirectory
            ) ? calculateDirectorySize(
                at: child.pathDescription,
                isDirectory: isDirectory.boolValue
            ) : 0
            measuredChild.sizeBytes = bytes
            measuredChild.sizeString = bytes > 0 ? formatBytes(bytes) : ""
            return measuredChild
        }
        let totalBytes = measuredChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
        measuredItem.children = measuredChildren
        measuredItem.sizeBytes = totalBytes
        measuredItem.sizeString = totalBytes > 0 ? formatBytes(totalBytes) : ""
        return measuredItem
    }

    private func uninstallItem(
        for application: InstalledApplication,
        relatedPaths: [String]
    ) -> CategoryItem {
        let paths = [application.path] + relatedPaths
        let identifier = application.bundleIdentifier ?? String(localized: "No Bundle Identifier")
        let rule = CleanRule(
            name: application.name,
            pathDescription: application.path,
            iconName: "app.fill",
            iconColor: .indigo,
            cleanType: .trashPaths(paths),
            note: LocalizedStringKey(
                "\(identifier) · App + \(relatedPaths.count) related items"
            ),
            scanMode: .uninstallApps
        )
        let children = paths.map { path in
            uninstallDetailItem(
                path: path,
                application: application,
                isAppBundle: path == application.path
            )
        }

        return CategoryItem(
            name: application.name,
            pathDescription: application.path,
            iconName: rule.iconName,
            iconColor: rule.iconColor,
            sizeBytes: 0,
            sizeString: "",
            rule: rule,
            children: children,
            finderPath: application.path,
            displayPath: application.name,
            description: rule.note,
            isAtomicSelection: true
        )
    }

    private func uninstallDetailItem(
        path: String,
        application: InstalledApplication,
        isAppBundle: Bool
    ) -> CategoryItem {
        let description: LocalizedStringKey
        if isAppBundle {
            if application.installSource == "Setapp" {
                description = "Application Bundle · Managed by Setapp"
            } else {
                description = "Application Bundle"
            }
        } else if application.managedPaths.contains(path) {
            description = "Homebrew Cask Installation"
        } else {
            description = associatedPathDescription(path)
        }
        let childRule = CleanRule(
            name: (path as NSString).lastPathComponent,
            pathDescription: path,
            iconName: isAppBundle ? "app.fill" : associationIcon(path),
            iconColor: isAppBundle ? .indigo : .secondary,
            cleanType: .none,
            note: description,
            isCheckboxHidden: true,
            scanMode: .uninstallApps
        )
        return CategoryItem(
            name: childRule.name,
            pathDescription: path,
            iconName: childRule.iconName,
            iconColor: childRule.iconColor,
            sizeBytes: 0,
            sizeString: "",
            rule: childRule,
            isSelected: false,
            isDisplayOnly: true,
            finderPath: path,
            description: description,
            isSelectionDetail: true,
            isRequiredSelectionDetail: isAppBundle
        )
    }

    private func associatedPathDescription(_ path: String) -> LocalizedStringKey {
        if path.contains("/Library/Group Containers/") {
            return "App Group Container"
        }
        if path.contains("/Library/Containers/") {
            return "App Container"
        }
        if path.contains("/Library/Application Scripts/") {
            return "Application Script"
        }
        if path.contains("/Library/SystemExtensions/") {
            return "System Extension"
        }
        if path.contains("/Library/Preferences/") {
            return "Preferences"
        }
        if path.contains("/Library/Caches/") {
            return "Cache"
        }
        if path.contains("/Library/Logs/") {
            return "Log"
        }
        if path.contains("/Library/LaunchAgents/")
            || path.contains("/Library/LaunchDaemons/") {
            return "Launch Agent"
        }
        if path.contains("/Library/Services/") {
            return "Service"
        }
        if path.contains("/Library/Internet Plug-Ins/") {
            return "Internet Plug-In"
        }
        if path.contains("/Library/Saved Application State/") {
            return "Saved App State"
        }
        return "Related App Data"
    }

    private func associationIcon(_ path: String) -> String {
        if path.contains("/Containers/") { return "shippingbox.fill" }
        if path.contains("/Application Scripts/") { return "scroll.fill" }
        if path.contains("/SystemExtensions/") { return "puzzlepiece.extension.fill" }
        if path.contains("/Preferences/") { return "gearshape.fill" }
        if path.contains("/Caches/") { return "archivebox.fill" }
        if path.contains("/Logs/") { return "doc.text.fill" }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") {
            return "bolt.fill"
        }
        if path.contains("/Services/") { return "gearshape.2.fill" }
        if path.contains("/Internet Plug-Ins/") { return "puzzlepiece.extension.fill" }
        return "folder.fill"
    }

    private enum AssociationMatchMode {
        case fuzzyIdentifier
        case exactBundleIdentifier
        case exactApplicationGroup
    }

    private func findAssociatedPaths(
        for applications: [InstalledApplication]
    ) -> (paths: [String: Set<String>], accessDenied: Bool) {
        let locations: [(
            path: String,
            allowsNameMatch: Bool,
            readsContainerMetadata: Bool,
            matchesLaunchProgram: Bool,
            matchMode: AssociationMatchMode
        )] = [
            ("~/Library/Application Support", true, false, false, .fuzzyIdentifier),
            ("~/Library/Caches", true, false, false, .fuzzyIdentifier),
            ("~/Library/Logs", true, false, false, .fuzzyIdentifier),
            ("~/Library/Preferences", false, false, false, .fuzzyIdentifier),
            ("~/Library/Preferences/ByHost", false, false, false, .fuzzyIdentifier),
            ("~/Library/Saved Application State", false, false, false, .fuzzyIdentifier),
            ("~/Library/WebKit", false, false, false, .fuzzyIdentifier),
            ("~/Library/HTTPStorages", false, false, false, .fuzzyIdentifier),
            ("~/Library/Cookies", false, false, false, .fuzzyIdentifier),
            ("~/Library/Containers", false, true, false, .exactBundleIdentifier),
            ("~/Library/Group Containers", false, true, false, .exactApplicationGroup),
            ("~/Library/Application Scripts", false, false, false, .exactBundleIdentifier),
            ("~/Library/Services", true, false, false, .fuzzyIdentifier),
            ("~/Library/Internet Plug-Ins", true, false, false, .fuzzyIdentifier),
            ("~/Library/LaunchAgents", false, false, true, .fuzzyIdentifier),
            ("/Library/LaunchAgents", false, false, true, .fuzzyIdentifier)
        ]
        let fileManager = FileManager.default
        var result: [String: Set<String>] = [:]
        var accessDenied = false

        for location in locations {
            let basePath = NSString(string: location.path).expandingTildeInPath
            let entries: [String]
            do {
                entries = try fileManager.contentsOfDirectory(atPath: basePath)
            } catch {
                accessDenied = accessDenied || isPermissionDenied(error)
                continue
            }

            for entry in entries where !entry.hasPrefix(".") {
                let fullPath = (basePath as NSString).appendingPathComponent(entry)
                if isSharedSetappInfrastructure(fullPath) {
                    continue
                }

                var candidates = [entry, (entry as NSString).deletingPathExtension]

                if location.readsContainerMetadata {
                    let metadataPath = (fullPath as NSString)
                        .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
                        if let plist = try? PropertyListSerialization.propertyList(
                            from: data,
                            options: [],
                            format: nil
                        ) as? [String: Any],
                           let identifier = plist["MCMMetadataIdentifier"] as? String,
                           !identifier.isEmpty {
                            candidates.append(identifier)
                        }
                    } catch {
                        accessDenied = accessDenied || isPermissionDenied(error)
                    }
                }

                let matchedApplications = applications.filter { application in
                    let identifierMatch = candidates.contains { candidate in
                        associationCandidate(
                            candidate,
                            matches: application,
                            allowsNameMatch: location.allowsNameMatch,
                            matchMode: location.matchMode
                        )
                    }
                    if identifierMatch { return true }
                    if location.matchesLaunchProgram {
                        return launchAgent(fullPath, launches: application)
                    }
                    return false
                }

                // Shared folders and group containers are intentionally left alone.
                // They can contain data that another installed app still needs.
                guard matchedApplications.count == 1,
                      let application = matchedApplications.first else {
                    continue
                }
                result[application.path, default: []].insert(fullPath)
            }
        }

        return (result, accessDenied)
    }

    private func associationCandidate(
        _ candidate: String,
        matches application: InstalledApplication,
        allowsNameMatch: Bool,
        matchMode: AssociationMatchMode
    ) -> Bool {
        let loweredCandidate = candidate.lowercased()

        switch matchMode {
        case .exactApplicationGroup:
            return application.applicationGroups.contains(loweredCandidate)
        case .exactBundleIdentifier:
            return application.relatedIdentifiers.contains(loweredCandidate)
        case .fuzzyIdentifier:
            for identifier in application.relatedIdentifiers {
                if loweredCandidate == identifier
                    || loweredCandidate.hasPrefix("\(identifier).")
                    || loweredCandidate.hasSuffix(".\(identifier)")
                    || loweredCandidate.contains(".\(identifier).") {
                    return true
                }
            }
            guard allowsNameMatch else { return false }
            let normalizedCandidate = normalizeAppIdentifier(candidate)
            return normalizedCandidate.count >= 4
                && application.matchingNames.contains(normalizedCandidate)
        }
    }

    // Setapp Desktop / shared agents must not be attributed to a single Setapp app.
    private func isSharedSetappInfrastructure(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let sharedMarkers = [
            "/applications/setapp/setapp.app",
            "/library/application support/setapp",
            "/library/caches/setapp",
            "/library/logs/setapp",
            "/library/launchagents/com.setapp.",
            "/library/containers/com.setapp."
        ]
        return sharedMarkers.contains { lowered.contains($0) }
    }

    private func launchAgent(
        _ plistPath: String,
        launches application: InstalledApplication
    ) -> Bool {
        guard plistPath.lowercased().hasSuffix(".plist"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return false
        }

        var programPaths: [String] = []
        if let program = plist["Program"] as? String {
            programPaths.append(program)
        }
        if let arguments = plist["ProgramArguments"] as? [String] {
            programPaths.append(contentsOf: arguments)
        }

        let appPath = application.path
        let escapedAppPath = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        return programPaths.contains { argument in
            argument == escapedAppPath
                || argument.hasPrefix("\(escapedAppPath)/")
                || argument.contains("\(escapedAppPath)/Contents/")
        }
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
            description: item.description,
            isAtomicSelection: item.isAtomicSelection,
            isSelectionDetail: item.isSelectionDetail,
            isRequiredSelectionDetail: item.isRequiredSelectionDetail,
            pendingSizePaths: item.pendingSizePaths
        )
    }

    nonisolated enum DetailSectionKind: Sendable {
        case installedTools
        case homeDirectory
    }

    nonisolated struct DetailSectionUpdate: Sendable {
        let section: DetailSectionKind
        let child: CategoryItem
    }

    // Build read-only informational sections, invoking onUpdate as each unit finishes.
    func scanDetailsIncremental(
        onUpdate: @escaping @Sendable (DetailSectionUpdate) -> Void
    ) {
        let coveredPaths = homeDirectoryEntryPaths()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "littleclean.details",
            qos: .utility,
            attributes: .concurrent
        )
        let ownedDirs = LockedBox<Set<String>>([])

        let emitTool: @Sendable (CategoryItem?) -> Void = { item in
            guard let item else { return }
            let filtered = filterHomeCoveredNodes([item], coveredPaths: coveredPaths)
            guard let first = filtered.first else { return }
            onUpdate(DetailSectionUpdate(section: .installedTools, child: first))
        }

        let dirs = nonSystemPathDirs()

        group.enter()
        queue.async {
            defer { group.leave() }
            let result = self.scanHomebrewTools(dirs: dirs)
            ownedDirs.with { $0.formUnion(result.ownedDirs) }
            emitTool(result.item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            let result = self.scanMacPortsTools(dirs: dirs)
            ownedDirs.with { $0.formUnion(result.ownedDirs) }
            emitTool(result.item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            var localOwned = Set<String>()
            let item = self.scanNodeInstalls(dirs: dirs, ownedDirs: &localOwned)
            ownedDirs.with { $0.formUnion(localOwned) }
            emitTool(item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            let result = self.scanPnpmTools(dirs: dirs)
            ownedDirs.with { $0.formUnion(result.ownedDirs) }
            emitTool(result.item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            let result = self.scanYarnTools(dirs: dirs)
            ownedDirs.with { $0.formUnion(result.ownedDirs) }
            emitTool(result.item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            let result = self.scanCargoTools(dirs: dirs)
            ownedDirs.with { $0.formUnion(result.ownedDirs) }
            emitTool(result.item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            emitTool(self.scanRubyGemsTools(dirs: dirs))
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            let result = self.scanGoTools(dirs: dirs)
            ownedDirs.with { $0.formUnion(result.ownedDirs) }
            emitTool(result.item)
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            emitTool(self.scanPipxTools(dirs: dirs))
        }

        for entry in homeDirectoryEntries() {
            group.enter()
            queue.async {
                defer { group.leave() }
                if let item = self.scanHomeDirectoryEntry(entry) {
                    onUpdate(DetailSectionUpdate(section: .homeDirectory, child: item))
                }
            }
        }

        group.wait()

        let finalOwned = ownedDirs.with { $0 }
        emitTool(scanOtherPathTools(dirs: dirs, ownedDirs: finalOwned))
    }

    // Build read-only informational sections synchronously on a background queue.
    func scanDetails() -> DetailScanResult {
        let accumulator = LockedBox<(tool: [CategoryItem], home: [CategoryItem])>(
            (tool: [], home: [])
        )
        scanDetailsIncremental { update in
            accumulator.with { state in
                switch update.section {
                case .installedTools:
                    state.tool.append(update.child)
                case .homeDirectory:
                    state.home.append(update.child)
                }
            }
        }

        var toolChildren = accumulator.with { $0.tool }
        var homeChildren = accumulator.with { $0.home }
        var items: [CategoryItem] = []
        if !toolChildren.isEmpty {
            toolChildren.sort { $0.sizeBytes > $1.sizeBytes }
            items.append(
                displayParent(
                    name: "Installed Tools",
                    label: "Installed Tools",
                    icon: "terminal.fill",
                    color: .primary,
                    note: "Read Only",
                    children: toolChildren
                )
            )
        }
        if !homeChildren.isEmpty {
            homeChildren.sort { $0.sizeBytes > $1.sizeBytes }
            items.append(
                displayParent(
                    name: "Home Directory",
                    label: "Home Directory",
                    icon: "folder.fill",
                    color: .blue,
                    note: "Non-system Items",
                    children: homeChildren
                )
            )
        }
        return DetailScanResult(items: items, containerAccessDenied: false)
    }

    // Fill in sizeBytes for items that listed paths up front (simulator versions, etc.).
    func measurePendingSizes(_ item: CategoryItem) -> CategoryItem {
        var result = item
        if let children = item.children, !children.isEmpty {
            let count = children.count
            let measured = LockedBox<[CategoryItem?]>([CategoryItem?](repeating: nil, count: count))
            DispatchQueue.concurrentPerform(iterations: count) { index in
                let child = measurePendingSizes(children[index])
                measured.with { $0[index] = child }
            }
            let resolved = measured.with { $0.compactMap { $0 } }
            result.children = resolved
            let total = resolved.reduce(Int64(0)) { $0 + $1.sizeBytes }
            result.sizeBytes = total
            result.sizeString = total > 0 ? formatBytes(total) : ""
            result.pendingSizePaths = nil
            return result
        }

        if let paths = item.pendingSizePaths, !paths.isEmpty {
            var total: Int64 = 0
            let fileManager = FileManager.default
            for path in paths {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
                    total += calculateDirectorySize(
                        at: path,
                        isDirectory: isDirectory.boolValue
                    )
                }
            }
            result.sizeBytes = total
            result.sizeString = total > 0 ? formatBytes(total) : ""
            result.pendingSizePaths = nil
        }
        return result
    }

    static func containsPendingSizes(_ item: CategoryItem) -> Bool {
        if let paths = item.pendingSizePaths, !paths.isEmpty {
            return true
        }
        return item.children?.contains(where: containsPendingSizes) ?? false
    }

    // List simulator devices by OS version without sizing; sizes load later via measurePendingSizes.
    private func scanSimulatorVersions(basePath: String) -> [CategoryItem] {
        let expandedPath = NSString(string: basePath).expandingTildeInPath
        let fileManager = FileManager.default
        guard let deviceFolders = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return []
        }

        var versionGroups: [String: [String]] = [:]

        for folder in deviceFolders {
            let fullFolderURL = URL(fileURLWithPath: expandedPath).appendingPathComponent(folder)
            let plistURL = fullFolderURL.appendingPathComponent("device.plist")

            guard fileManager.fileExists(atPath: plistURL.path) else { continue }

            var versionName = "Unknown Simulator"
            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
               ) as? [String: Any],
               let runtime = plist["runtime"] as? String {
                versionName = parseRuntimeName(runtime)
            }
            versionGroups[versionName, default: []].append(fullFolderURL.path)
        }

        guard !versionGroups.isEmpty else { return [] }

        let versionChildren: [CategoryItem] = versionGroups
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { versionName, paths in
                let sortedPaths = paths.sorted()
                let deviceCount = sortedPaths.count
                let noteKey: LocalizedStringKey = "\(deviceCount) Devices"
                return CategoryItem(
                    name: versionName,
                    pathDescription: versionName,
                    iconName: "iphone",
                    iconColor: .purple,
                    sizeBytes: 0,
                    sizeString: "",
                    rule: CleanRule(
                        name: versionName,
                        pathDescription: versionName,
                        iconName: "iphone",
                        iconColor: .purple,
                        cleanType: .none,
                        note: noteKey,
                        isCheckboxHidden: true,
                        scanMode: .deepAnalysis
                    ),
                    isDisplayOnly: true,
                    finderPath: sortedPaths.first ?? expandedPath,
                    description: noteKey,
                    pendingSizePaths: sortedPaths
                )
            }

        let parentRule = CleanRule(
            name: "Simulator Devices by Version",
            pathDescription: basePath,
            iconName: "iphone.badge.play",
            iconColor: .purple,
            cleanType: .none,
            note: "\(versionChildren.count) Versions",
            isDynamicSimulatorRule: true,
            isCheckboxHidden: true,
            scanMode: .deepAnalysis
        )

        let parent = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: 0,
            sizeString: "",
            rule: parentRule,
            children: versionChildren,
            isDisplayOnly: true,
            finderPath: expandedPath
        )
        return [parent]
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
    private func scanUnavailableSimulators(
        basePath: String,
        deferSizes: Bool = false
    ) -> [CategoryItem] {
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
                guard fileManager.fileExists(atPath: devicePath, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let bytes: Int64
                if deferSizes {
                    bytes = 0
                } else {
                    bytes = calculateDirectorySize(at: devicePath, isDirectory: true)
                }

                totalBytes += bytes
                let deviceName = (device["name"] as? String) ?? udid
                let displayPath = "\(basePath)/\(udid)"

                let rule = CleanRule(
                    name: deviceName,
                    pathDescription: displayPath,
                    iconName: "iphone.slash",
                    iconColor: .red,
                    cleanType: .runCommand(
                        executable: "/usr/bin/xcrun",
                        args: ["simctl", "delete", udid]
                    ),
                    note: "Unavailable"
                )
                let item = CategoryItem(
                    name: deviceName,
                    pathDescription: displayPath,
                    iconName: "iphone.slash",
                    iconColor: .red,
                    sizeBytes: bytes,
                    sizeString: bytes > 0 ? formatBytes(bytes) : "",
                    rule: rule,
                    pendingSizePaths: deferSizes ? [devicePath] : nil
                )
                childItems.append(item)
            }
        }

        guard !childItems.isEmpty else { return [] }

        if !deferSizes {
            childItems.sort { $0.sizeBytes > $1.sizeBytes }
        }

        let parentRule = CleanRule(
            name: "Unavailable Simulators",
            pathDescription: basePath,
            iconName: "iphone.slash",
            iconColor: .red,
            cleanType: .none,
            note: "Missing Runtime",
            isDynamicUnavailableSimulatorRule: true,
            isCheckboxHidden: true
        )
        let parent = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: totalBytes > 0 ? formatBytes(totalBytes) : "",
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
        "flutter": "Flutter SDK",
        "venvs": "Python Venvs", ".virtualenvs": "Python Venvs", ".venvs": "Python Venvs", ".envs": "Python Venvs",
        "miniconda3": "Conda", "anaconda3": "Conda", "miniforge3": "Conda", "mambaforge3": "Conda",
        "miniconda": "Conda", "anaconda": "Conda", "miniforge": "Conda", "mambaforge": "Conda",
        "androidstudioprojects": "Android Projects",
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
        ".virtualenvs": ("curlybraces", .yellow),
        ".venvs": ("curlybraces", .yellow),
        ".envs": ("curlybraces", .yellow),
        "miniconda3": ("leaf.fill", .green),
        "anaconda3": ("leaf.fill", .green),
        "miniforge3": ("leaf.fill", .green),
        "mambaforge3": ("leaf.fill", .green),
        "miniconda": ("leaf.fill", .green),
        "anaconda": ("leaf.fill", .green),
        "miniforge": ("leaf.fill", .green),
        "mambaforge": ("leaf.fill", .green),
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

        var noteKey: String {
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

        var localizedName: String {
            NSLocalizedString(noteKey, comment: "")
        }

        var note: LocalizedStringKey {
            LocalizedStringKey(noteKey)
        }
    }

    private func resolveAppName(for rawIdentifier: String, path: String) -> String? {
        let fileManager = FileManager.default

        // If identifier is a generic subdirectory name like "Data", "Library", "System", "Contents",
        // look up the path hierarchy for the real app/bundle folder name.
        var identifier = rawIdentifier
        let pathComponents = (path as NSString).pathComponents
        let genericNames = Set(["data", "library", "contents", "application support", "containers", "group containers", "caches"])

        if genericNames.contains(identifier.lowercased()) {
            for component in pathComponents.reversed() {
                let lower = component.lowercased()
                if !genericNames.contains(lower) && !lower.hasPrefix("~") && lower != "/" && lower != "users" {
                    identifier = component
                    break
                }
            }
        }

        // 1. If identifier looks like a bundle id (e.g. com.tencent.xinWeChat, com.docker.docker)
        if identifier.contains(".") && !identifier.hasPrefix(".") {
            let cleanID = identifier.trimmingCharacters(in: .whitespaces)
            var bundleID = cleanID
            let components = cleanID.split(separator: ".")
            if let first = components.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                bundleID = components.dropFirst().joined(separator: ".")
            }

            var candidateID = bundleID
            while !candidateID.isEmpty {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidateID) {
                    let displayName = fileManager.displayName(atPath: url.path)
                    let name = (displayName as NSString).deletingPathExtension
                    if !name.isEmpty {
                        return name
                    }
                }
                let parts = candidateID.split(separator: ".")
                if parts.count > 2 {
                    candidateID = parts.dropLast().joined(separator: ".")
                } else {
                    break
                }
            }

            // Fallback: parse last component of bundle ID into readable product name
            if let last = components.last {
                let cleanLast = String(last)
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                let words = cleanLast.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
                let lowerWords = words.lowercased()
                if !words.isEmpty && lowerWords != "app" && lowerWords != "mac" && lowerWords != "helper" && lowerWords != "desktop" {
                    if components.count >= 2 {
                        let vendor = String(components[1]).capitalized
                        let lowerVendor = vendor.lowercased()
                        if lowerVendor != "com" && lowerVendor != "org" && lowerVendor != "net" && lowerVendor != lowerWords && lowerVendor != "github" && lowerVendor != "apple" {
                            return "\(vendor) \(words)"
                        }
                    }
                    return words
                }
            }
        }

        // 2. Check if parent folder carries product brand (e.g., Google/Chrome)
        if pathComponents.count >= 2 {
            let parent = pathComponents[pathComponents.count - 2]
            let lowerParent = parent.lowercased()
            if !genericNames.contains(lowerParent) && !lowerParent.hasPrefix("~") {
                return "\(parent) \(identifier)"
            }
        }

        return identifier
    }

    // Describe only the kinds of content found in a directory. This classification is
    // deliberately independent from whether the directory is a leftover or safe to delete.
    // Sampling is bounded so it works for arbitrary apps without making scans unreasonably slow.
    private func describeDirectoryContents(at path: String) -> LocalizedStringKey? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return nil }
        let ignoredMetadata = Set([".ds_store", ".localized"])
        let filteredEntries = entries.filter {
            let lower = $0.lowercased()
            return !ignoredMetadata.contains(lower) && !lower.hasPrefix(".") && !lower.hasSuffix("_lock")
        }
        guard !filteredEntries.isEmpty else {
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

        let folderName = (path as NSString).lastPathComponent
        let resolvedApp = resolveAppName(for: folderName, path: path)

        func buildNote(body: String) -> LocalizedStringKey {
            if let app = resolvedApp, !app.isEmpty, app.lowercased() != body.lowercased() {
                return LocalizedStringKey("\(app) · \(body)")
            }
            return LocalizedStringKey(body)
        }

        if !ranked.isEmpty {
            if ranked.count == 1 {
                let singleCatName = ranked[0].key.localizedName
                return buildNote(body: singleCatName)
            } else {
                let catNames = ranked.prefix(3).map { $0.key.localizedName }
                let catJoined = catNames.joined(separator: " · ")
                return buildNote(body: catJoined)
            }
        } else {
            return buildNote(body: "App Data")
        }
    }

    // Dynamically scan for folders in Application Support that belong to UNINSTALLED applications
    private func scanAppLeftovers(
        basePath: String,
        deferSizes: Bool = false
    ) -> [CategoryItem] {
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
            let isAppInstalled = folderMatchesInstalledApp(
                folder,
                lowerFolder: lowerFolder,
                normalizedFolder: normalizedFolder,
                installedApps: installedApps
            )

            // If the app is currently installed, SKIP IT (Not a leftover!)
            if isAppInstalled {
                continue
            }

            let fullPath = (expandedBasePath as NSString).appendingPathComponent(folder)
            var isDirectory: ObjCBool = false

            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let sizeBytes = deferSizes
                    ? Int64(0)
                    : calculateDirectorySize(at: fullPath, isDirectory: true)
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
                    sizeString: sizeBytes > 0 ? formatBytes(sizeBytes) : "",
                    rule: childRule,
                    pendingSizePaths: deferSizes ? [fullPath] : nil
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
            isDynamicLeftoversRule: true,
            isCheckboxHidden: true
        )

        let parentItem = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: totalBytes > 0 ? formatBytes(totalBytes) : "",
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
    private func scanContainerLeftovers(
        basePath: String,
        deferSizes: Bool = false
    ) -> (items: [CategoryItem], accessDenied: Bool) {
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
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            // Resolve the owning bundle id from the container manager metadata plist,
            // falling back to the folder name. UUID-named containers rely on the plist.
            let metadataPlist = (fullPath as NSString)
                .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            var bundleID = entry
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: metadataPlist))
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
            if folderMatchesInstalledApp(
                bundleID,
                lowerFolder: lowerBundle,
                normalizedFolder: normalizedBundle,
                installedApps: installedApps
            ) {
                continue
            }

            let sizeBytes = deferSizes
                ? Int64(0)
                : calculateDirectorySize(at: fullPath, isDirectory: true)
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
                note: describeDirectoryContents(at: dataPath)
                    ?? describeDirectoryContents(at: fullPath)
            )

            let childItem = CategoryItem(
                name: childRule.name,
                pathDescription: childRule.pathDescription,
                iconName: childRule.iconName,
                iconColor: childRule.iconColor,
                sizeBytes: sizeBytes,
                sizeString: sizeBytes > 0 ? formatBytes(sizeBytes) : "",
                rule: childRule,
                pendingSizePaths: deferSizes ? [fullPath] : nil
            )
            childItems.append(childItem)
        }

        guard !childItems.isEmpty else { return ([], false) }

        if !deferSizes {
            childItems.sort { $0.sizeBytes > $1.sizeBytes }
        }

        let parentRule = CleanRule(
            name: String(localized: "Container Leftovers"),
            pathDescription: basePath,
            iconName: "shippingbox.fill",
            iconColor: .pink,
            cleanType: .none,
            note: "Container Leftovers",
            isDynamicContainerLeftoversRule: true,
            isCheckboxHidden: true
        )

        let parentItem = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: totalBytes,
            sizeString: totalBytes > 0 ? formatBytes(totalBytes) : "",
            rule: parentRule,
            children: childItems
        )

        return ([parentItem], false)
    }

    // Safe Cleanup leftovers that are not Application Support folders or sandbox
    // containers: App Extension scripts, Internet Plug-Ins, Services, login-item
    // LaunchAgents whose Program is gone, and System Extensions whose host app
    // is gone. Safari's own ~/Library/Safari data is intentionally not scanned.
    private func scanExtensionLeftovers(
        deferSizes: Bool = false
    ) -> (items: [CategoryItem], accessDenied: Bool) {
        let fileManager = FileManager.default
        let installedApps = fetchInstalledAppIdentifiers()
        var childItems: [CategoryItem] = []
        var seenPaths = Set<String>()
        var accessDenied = false

        func appendChild(
            name: String,
            fullPath: String,
            iconName: String,
            note: LocalizedStringKey,
            isDirectory: Bool
        ) {
            let standardized = URL(fileURLWithPath: fullPath).standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { return }
            let sizeBytes = deferSizes
                ? Int64(0)
                : calculateDirectorySize(at: standardized, isDirectory: isDirectory)
            let childRule = CleanRule(
                name: name,
                pathDescription: displayPath(for: standardized),
                iconName: iconName,
                iconColor: .pink,
                cleanType: .deleteDirectoryTree,
                note: note
            )
            childItems.append(
                CategoryItem(
                    name: childRule.name,
                    pathDescription: childRule.pathDescription,
                    iconName: childRule.iconName,
                    iconColor: childRule.iconColor,
                    sizeBytes: sizeBytes,
                    sizeString: sizeBytes > 0 ? formatBytes(sizeBytes) : "",
                    rule: childRule,
                    pendingSizePaths: deferSizes ? [standardized] : nil
                )
            )
        }

        func entries(at path: String) -> [String] {
            do {
                return try fileManager.contentsOfDirectory(atPath: path)
            } catch {
                accessDenied = accessDenied || isPermissionDenied(error)
                return []
            }
        }

        let applicationScripts = NSString(string: "~/Library/Application Scripts")
            .expandingTildeInPath
        let containersRoot = NSString(string: "~/Library/Containers").expandingTildeInPath
        let containerEntries: Set<String>?
        do {
            containerEntries = Set(try fileManager.contentsOfDirectory(atPath: containersRoot))
        } catch {
            accessDenied = accessDenied || isPermissionDenied(error)
            containerEntries = isPermissionDenied(error) ? nil : []
        }

        for entry in entries(at: applicationScripts) where !entry.hasPrefix(".") {
            if entry == "--TeamIdentifierPrefix-" { continue }
            let fullPath = (applicationScripts as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                continue
            }

            let owner: String?
            if looksLikeUUID(entry) {
                // UUID folders are often system containers. Only list them when
                // the owning bundle id is known and is not Apple/system software.
                guard let containerEntries else { continue }
                guard containerEntries.contains(entry) else { continue }
                switch owningBundleID(forContainerUUID: entry) {
                case .accessDenied:
                    accessDenied = true
                    continue
                case .unresolved, .missingContainer:
                    continue
                case .identifier(let bundleID):
                    owner = bundleID
                }
            } else {
                owner = entry
            }

            guard let owner,
                  !leftoverBelongsToInstalledSoftware(owner, installedApps: installedApps),
                  !isAppleSignedItem(at: fullPath) else {
                continue
            }

            appendChild(
                name: entry,
                fullPath: fullPath,
                iconName: "scroll.fill",
                note: "Application Script",
                isDirectory: isDirectory.boolValue
            )
        }

        let pluginRoots = [
            NSString(string: "~/Library/Internet Plug-Ins").expandingTildeInPath,
            "/Library/Internet Plug-Ins"
        ]
        for root in pluginRoots {
            for entry in entries(at: root) where !entry.hasPrefix(".") {
                let fullPath = (root as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                    continue
                }
                let identifier = bundleIdentifier(at: fullPath)
                    ?? (entry as NSString).deletingPathExtension
                if leftoverBelongsToInstalledSoftware(identifier, installedApps: installedApps)
                    || isAppleSignedItem(at: fullPath) {
                    continue
                }
                appendChild(
                    name: entry,
                    fullPath: fullPath,
                    iconName: "puzzlepiece.extension.fill",
                    note: "Internet Plug-In",
                    isDirectory: isDirectory.boolValue
                )
            }
        }

        let serviceRoots = [
            NSString(string: "~/Library/Services").expandingTildeInPath,
            "/Library/Services"
        ]
        for root in serviceRoots {
            for entry in entries(at: root) where !entry.hasPrefix(".") {
                let fullPath = (root as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                    continue
                }
                // User-created Automator workflows often have no bundle id; leave them alone.
                guard let identifier = bundleIdentifier(at: fullPath), !identifier.isEmpty else {
                    continue
                }
                if leftoverBelongsToInstalledSoftware(identifier, installedApps: installedApps)
                    || isAppleSignedItem(at: fullPath) {
                    continue
                }
                appendChild(
                    name: (entry as NSString).deletingPathExtension,
                    fullPath: fullPath,
                    iconName: "gearshape.2.fill",
                    note: "Service",
                    isDirectory: isDirectory.boolValue
                )
            }
        }

        let launchAgentRoots = [
            NSString(string: "~/Library/LaunchAgents").expandingTildeInPath,
            "/Library/LaunchAgents"
        ]
        for root in launchAgentRoots {
            for entry in entries(at: root) where !entry.hasPrefix(".") && entry.lowercased().hasSuffix(".plist") {
                let fullPath = (root as NSString).appendingPathComponent(entry)
                guard let leftover = launchAgentLeftover(at: fullPath) else { continue }
                appendChild(
                    name: leftover.label,
                    fullPath: fullPath,
                    iconName: "bolt.fill",
                    note: "Login Item",
                    isDirectory: false
                )
            }
        }

        let systemExtensionsRoot = "/Library/SystemExtensions"
        switch systemExtensionLeftovers() {
        case .accessDenied:
            accessDenied = true
        case .extensions(let leftovers):
            for leftover in leftovers {
                let fullPath = (systemExtensionsRoot as NSString)
                    .appendingPathComponent(leftover.uniqueID)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                    continue
                }
                if leftoverBelongsToInstalledSoftware(
                    leftover.identifier,
                    installedApps: installedApps
                ) || isAppleSignedItem(at: fullPath) {
                    continue
                }
                appendChild(
                    name: leftover.identifier,
                    fullPath: fullPath,
                    iconName: "puzzlepiece.extension.fill",
                    note: "System Extension",
                    isDirectory: isDirectory.boolValue
                )
            }
        }

        guard !childItems.isEmpty else { return ([], accessDenied) }

        let grouped = Dictionary(grouping: childItems) { item in
            (item.pathDescription as NSString).deletingLastPathComponent
        }
        var parents: [CategoryItem] = []
        for (groupPath, items) in grouped {
            var groupedItems = items
            if !deferSizes {
                groupedItems.sort { $0.sizeBytes > $1.sizeBytes }
            }
            let total = groupedItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let parentRule = CleanRule(
                name: groupPath,
                pathDescription: groupPath,
                iconName: groupedItems.first?.iconName ?? "puzzlepiece.extension.fill",
                iconColor: .pink,
                cleanType: .none,
                note: groupedItems.first?.rule.note,
                isDynamicExtensionLeftoversRule: true,
                isCheckboxHidden: true
            )
            parents.append(
                CategoryItem(
                    name: parentRule.name,
                    pathDescription: parentRule.pathDescription,
                    iconName: parentRule.iconName,
                    iconColor: parentRule.iconColor,
                    sizeBytes: total,
                    sizeString: total > 0 ? formatBytes(total) : "",
                    rule: parentRule,
                    children: groupedItems
                )
            )
        }
        parents.sort {
            $0.pathDescription.localizedCaseInsensitiveCompare($1.pathDescription) == .orderedAscending
        }
        return (parents, accessDenied)
    }

    private func displayPath(for fullPath: String) -> String {
        let home = NSHomeDirectory()
        if fullPath == home {
            return "~"
        }
        if fullPath.hasPrefix(home + "/") {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }

    private func looksLikeUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5,
              zip(parts, lengths).allSatisfy({ $0.count == $1 }) else {
            return false
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.unicodeScalars.allSatisfy { $0 == "-" || hex.contains($0) }
    }

    private enum ContainerOwnerResult {
        case identifier(String)
        case missingContainer
        case unresolved
        case accessDenied
    }

    private func owningBundleID(forContainerUUID uuid: String) -> ContainerOwnerResult {
        let containerPath = NSString(string: "~/Library/Containers/\(uuid)")
            .expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: containerPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missingContainer
        }

        let metadataPlist = (containerPath as NSString)
            .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: metadataPlist))
            if let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
               let identifier = plist["MCMMetadataIdentifier"] as? String,
               !identifier.isEmpty {
                return .identifier(identifier)
            }
            return .unresolved
        } catch {
            return isPermissionDenied(error) ? .accessDenied : .unresolved
        }
    }

    private func leftoverBelongsToInstalledSoftware(
        _ identifier: String,
        installedApps: Set<String>
    ) -> Bool {
        for candidate in leftoverMatchCandidates(identifier) {
            if isAppleOwnedIdentifier(candidate) {
                return true
            }
            let lower = candidate.lowercased()
            if lower.hasPrefix("dev.arayofsunshine.littleclean") {
                return true
            }
            if folderMatchesInstalledApp(
                candidate,
                lowerFolder: lower,
                normalizedFolder: normalizeString(candidate),
                installedApps: installedApps
            ) {
                return true
            }
            if InstalledToolIndex.shared.isInstalledTool(candidate) {
                return true
            }
            if SystemComponentIndex.shared.isSystemOwned(candidate) {
                return true
            }
        }
        return false
    }

    private func leftoverMatchCandidates(_ identifier: String) -> [String] {
        var candidates = [identifier]
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        if let first = parts.first,
           first.count == 10,
           first.allSatisfy({ $0.isLetter || $0.isNumber }),
           parts.count >= 2 {
            let stripped = parts.dropFirst().joined(separator: ".")
            candidates.append(stripped)
            let lower = stripped.lowercased()
            if lower.hasPrefix("group.") {
                candidates.append(String(stripped.dropFirst(6)))
            } else if lower.hasPrefix("groups.") {
                candidates.append(String(stripped.dropFirst(7)))
            }
        } else {
            let lower = identifier.lowercased()
            if lower.hasPrefix("group.") {
                candidates.append(String(identifier.dropFirst(6)))
            } else if lower.hasPrefix("groups.") {
                candidates.append(String(identifier.dropFirst(7)))
            }
        }
        return candidates
    }

    private func isSystemOwnedExtensionIdentifier(_ identifier: String) -> Bool {
        leftoverMatchCandidates(identifier).contains { isAppleOwnedIdentifier($0) }
    }

    private func isAppleOwnedIdentifier(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        if lower == "com.apple"
            || lower.hasPrefix("com.apple.")
            || lower.hasPrefix("apple.")
            || lower.hasPrefix("groups.com.apple.")
            || lower.hasPrefix("group.com.apple.")
            || lower.contains(".com.apple.")
            || lower.hasSuffix(".com.apple") {
            return true
        }
        let parts = lower.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10 else { return false }
        let rest = String(parts[1])
        return rest == "com.apple"
            || rest.hasPrefix("com.apple.")
            || rest.hasPrefix("apple.")
            || rest.hasPrefix("groups.com.apple.")
            || rest.hasPrefix("group.com.apple.")
    }

    private func isAppleSignedItem(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
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
              let appleAnchor else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            appleAnchor
        ) == errSecSuccess
    }

    private func isSystemManagedPath(_ path: String) -> Bool {
        path.hasPrefix("/System/")
            || path.hasPrefix("/System/Cryptexes/")
            || path.hasPrefix("/Library/Apple/")
            || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/usr/bin/")
            || path.hasPrefix("/bin/")
            || path.hasPrefix("/sbin/")
            || path.hasPrefix("/private/var/db/")
    }

    private func bundleIdentifier(at path: String) -> String? {
        if let identifier = Bundle(path: path)?.bundleIdentifier, !identifier.isEmpty {
            return identifier
        }
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty else {
            return nil
        }
        return identifier
    }

    private func launchAgentLeftover(at plistPath: String) -> (label: String, program: String)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }

        let filename = (plistPath as NSString).deletingPathExtension
        let label = (plist["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? filename
        if leftoverBelongsToInstalledSoftware(
            label,
            installedApps: fetchInstalledAppIdentifiers()
        ) {
            return nil
        }
        guard let program = launchAgentTargetPath(in: plist) else {
            return nil
        }
        if isSystemManagedPath(program) || isAppleSignedItem(at: program) {
            return nil
        }
        if FileManager.default.fileExists(atPath: program) {
            return nil
        }
        return (label, program)
    }

    private func launchAgentTargetPath(in plist: [String: Any]) -> String? {
        if let program = plist["Program"] as? String, !program.isEmpty {
            return NSString(string: program).expandingTildeInPath
        }
        guard let arguments = plist["ProgramArguments"] as? [String],
              let first = arguments.first, !first.isEmpty else {
            return nil
        }
        let expandedFirst = NSString(string: first).expandingTildeInPath
        if Self.launchWrapperExecutables.contains(expandedFirst) {
            for argument in arguments.dropFirst() where !argument.hasPrefix("-") {
                if argument.hasPrefix("/") || argument.hasPrefix("~") {
                    return NSString(string: argument).expandingTildeInPath
                }
            }
        }
        return expandedFirst
    }

    private static let launchWrapperExecutables: Set<String> = [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh",
        "/usr/bin/env", "/usr/bin/open"
    ]

    private enum SystemExtensionScanResult {
        case extensions([(uniqueID: String, identifier: String)])
        case accessDenied
    }

    private func systemExtensionLeftovers() -> SystemExtensionScanResult {
        let dbPath = "/Library/SystemExtensions/db.plist"
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        } catch {
            return isPermissionDenied(error) ? .accessDenied : .extensions([])
        }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let extensions = plist["extensions"] as? [[String: Any]] else {
            return .extensions([])
        }

        var leftovers: [(uniqueID: String, identifier: String)] = []
        for record in extensions {
            guard let uniqueID = record["uniqueID"] as? String, !uniqueID.isEmpty else {
                continue
            }
            let identifier = (record["identifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? uniqueID
            if looksLikeUUID(identifier)
                || isSystemOwnedExtensionIdentifier(identifier) {
                continue
            }
            if let originPath = record["originPath"] as? String, !originPath.isEmpty {
                if isSystemManagedPath(originPath)
                    || hostApplicationExists(atOriginPath: originPath)
                    || isAppleSignedItem(at: originPath) {
                    continue
                }
                leftovers.append((uniqueID, identifier))
                continue
            }
            if leftoverBelongsToInstalledSoftware(
                identifier,
                installedApps: fetchInstalledAppIdentifiers()
            ) {
                continue
            }
            leftovers.append((uniqueID, identifier))
        }
        return .extensions(leftovers)
    }

    private func hostApplicationExists(atOriginPath originPath: String) -> Bool {
        var url = URL(fileURLWithPath: originPath)
        while url.path != "/" {
            if url.pathExtension.lowercased() == "app" {
                return FileManager.default.fileExists(atPath: url.path)
            }
            url.deleteLastPathComponent()
        }
        return false
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

                let dataPath = (fullPath as NSString).appendingPathComponent("Data")
                let noteDesc = describeDirectoryContents(at: dataPath) ?? describeDirectoryContents(at: fullPath)
                childItems.append(displayItem(
                    name: bundleID,
                    label: "\(basePath)/\(entry)",
                    icon: "shippingbox.fill",
                    color: .blue,
                    sizeBytes: sizeResult.bytes,
                    finderPath: fullPath,
                    description: noteDesc
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
            includingPropertiesForKeys: Self.diskUsageResourceKeys + [.isDirectoryKey],
            errorHandler: { _, error in
                accessDenied = accessDenied || isPermissionDenied(error)
                return true
            }
        ) else {
            return (0, true)
        }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: Set(Self.diskUsageResourceKeys + [.isDirectoryKey])),
               values.isDirectory == false,
               let size = Self.diskUsageBytes(from: values) {
                totalBytes += size
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

    // macOS has no public FDA API; probe TCC-protected locations this app needs.
    // A successful read of another app's container implies Full Disk Access.
    func hasFullDiskAccess() -> Bool {
        let candidates = [
            "~/Library/Containers/com.apple.stocks",
            "~/Library/Safari",
            "~/Library/Mail"
        ]
        var sawPermissionDenied = false
        for path in candidates {
            let expanded = NSString(string: path).expandingTildeInPath
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: expanded)
                return true
            } catch {
                if isPermissionDenied(error) {
                    sawPermissionDenied = true
                }
            }
        }
        return !sawPermissionDenied
    }

    // Scan known tool cache locations under the home directory
    private func scanHomeCaches(
        basePath: String,
        deferSizes: Bool = false
    ) -> [CategoryItem] {
        let home = NSHomeDirectory()
        let fileManager = FileManager.default

        // Curated, safe-to-clear tool caches (contents only; folder is kept)
        let knownCaches: [(name: String, subpath: String, icon: String, color: Color)] = [
            ("App Caches", "Library/Caches", "archivebox.fill", .orange),
            ("XDG Cache", ".cache", "shippingbox.fill", .orange),
            ("npm Cache", ".npm", "shippingbox.fill", .red),
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
        let gradleCaches: [(name: String, subpath: String)] = [
            ("Cache", ".gradle/caches"),
            ("Wrapper Distributions", ".gradle/wrapper/dists"),
            ("Temporary Files", ".gradle/.tmp"),
            ("Daemon Logs", ".gradle/daemon"),
            ("Native Libraries", ".gradle/native")
        ]

        func makeCacheItem(
            name: String,
            subpath: String,
            icon: String,
            color: Color
        ) -> CategoryItem? {
            let fullPath = (home as NSString).appendingPathComponent(subpath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir),
                  isDir.boolValue else { return nil }

            let bytes: Int64
            if deferSizes {
                bytes = 0
            } else {
                bytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            }

            let displayPath = "~/\(subpath)"
            let rule = CleanRule(
                name: name,
                pathDescription: displayPath,
                iconName: icon,
                iconColor: color,
                cleanType: .deleteDirectory,
                note: LocalizedStringKey(name)
            )
            return CategoryItem(
                name: name,
                pathDescription: displayPath,
                iconName: icon,
                iconColor: color,
                sizeBytes: bytes,
                sizeString: bytes > 0 ? formatBytes(bytes) : "",
                rule: rule,
                pendingSizePaths: deferSizes ? [fullPath] : nil
            )
        }

        var childItems: [CategoryItem] = []

        for cache in knownCaches {
            if let item = makeCacheItem(
                name: cache.name,
                subpath: cache.subpath,
                icon: cache.icon,
                color: cache.color
            ) {
                childItems.append(item)
            }
        }

        var gradleChildren = gradleCaches.compactMap { cache in
            makeCacheItem(
                name: cache.name,
                subpath: cache.subpath,
                icon: "hammer.fill",
                color: .purple
            )
        }
        if !deferSizes {
            gradleChildren.sort { $0.sizeBytes > $1.sizeBytes }
        }
        if !gradleChildren.isEmpty {
            let totalBytes = gradleChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let parentRule = CleanRule(
                name: "Gradle",
                pathDescription: "~/.gradle",
                iconName: "cup.and.saucer.fill",
                iconColor: .teal,
                cleanType: .none,
                note: "Gradle Build",
                isCheckboxHidden: true
            )
            childItems.append(
                CategoryItem(
                    name: parentRule.name,
                    pathDescription: parentRule.pathDescription,
                    iconName: parentRule.iconName,
                    iconColor: parentRule.iconColor,
                    sizeBytes: totalBytes,
                    sizeString: totalBytes > 0 ? formatBytes(totalBytes) : "",
                    rule: parentRule,
                    children: gradleChildren
                )
            )
        }

        childItems.append(contentsOf: scanChromeCaches(deferSizes: deferSizes))

        return childItems
    }

    // Regenerable Chrome caches under Application Support. HTTP cache lives in
    // ~/Library/Caches/Google/Chrome and is already covered by App Caches.
    private func scanChromeCaches(deferSizes: Bool = false) -> [CategoryItem] {
        let chromeRoot = NSString(string: "~/Library/Application Support/Google/Chrome")
            .expandingTildeInPath
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: chromeRoot, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? fileManager.contentsOfDirectory(atPath: chromeRoot) else {
            return []
        }

        let profileNames = entries.filter { entry in
            entry == "Default"
                || entry == "Guest Profile"
                || entry == "System Profile"
                || entry.hasPrefix("Profile ")
        }.sorted()

        let profileCaches: [(relative: String, name: String, note: LocalizedStringKey)] = [
            ("Cache", "HTTP Cache", "HTTP Cache"),
            ("Code Cache", "Code Cache", "Code Cache"),
            ("GPUCache", "GPU Cache", "GPU Cache"),
            ("Service Worker/CacheStorage", "Service Worker Cache", "Service Worker Cache"),
            ("Service Worker/ScriptCache", "Service Worker Script Cache", "Service Worker Script Cache")
        ]
        let browserCaches: [(relative: String, name: String, note: LocalizedStringKey)] = [
            ("ShaderCache", "Shader Cache", "Shader Cache"),
            ("GrShaderCache", "Skia Shader Cache", "Skia Shader Cache"),
            ("GraphiteDawnCache", "Graphite Cache", "Graphite Cache"),
            ("GPUPersistentCache", "GPU Persistent Cache", "GPU Persistent Cache")
        ]

        var childItems: [CategoryItem] = []

        func appendCache(relativePath: String, name: String, note: LocalizedStringKey) {
            let fullPath = (chromeRoot as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir),
                  isDir.boolValue else { return }

            let bytes: Int64
            if deferSizes {
                bytes = 0
            } else {
                bytes = calculateDirectorySize(at: fullPath, isDirectory: true)
            }

            let displayPath = "~/Library/Application Support/Google/Chrome/\(relativePath)"
            let rule = CleanRule(
                name: name,
                pathDescription: displayPath,
                iconName: "globe",
                iconColor: .orange,
                cleanType: .deleteDirectory,
                note: note
            )
            childItems.append(
                CategoryItem(
                    name: name,
                    pathDescription: displayPath,
                    iconName: "globe",
                    iconColor: .orange,
                    sizeBytes: bytes,
                    sizeString: bytes > 0 ? formatBytes(bytes) : "",
                    rule: rule,
                    pendingSizePaths: deferSizes ? [fullPath] : nil
                )
            )
        }

        for profile in profileNames {
            for cache in profileCaches {
                let label = profileNames.count > 1
                    ? "\(cache.name) (\(profile))"
                    : cache.name
                appendCache(
                    relativePath: "\(profile)/\(cache.relative)",
                    name: label,
                    note: cache.note
                )
            }
        }
        for cache in browserCaches {
            appendCache(
                relativePath: cache.relative,
                name: cache.name,
                note: cache.note
            )
        }

        guard !childItems.isEmpty else { return [] }

        if !deferSizes {
            childItems.sort { $0.sizeBytes > $1.sizeBytes }
        }

        let parentRule = CleanRule(
            name: String(localized: "Chrome Cache"),
            pathDescription: "~/Library/Application Support/Google/Chrome",
            iconName: "globe",
            iconColor: .orange,
            cleanType: .none,
            note: "Chrome Cache",
            isDynamicChromeCacheRule: true,
            isCheckboxHidden: true
        )
        var parent = CategoryItem(
            name: parentRule.name,
            pathDescription: parentRule.pathDescription,
            iconName: parentRule.iconName,
            iconColor: parentRule.iconColor,
            sizeBytes: childItems.reduce(Int64(0)) { $0 + $1.sizeBytes },
            sizeString: "",
            rule: parentRule,
            children: childItems
        )
        parent.sizeString = parent.sizeBytes > 0 ? formatBytes(parent.sizeBytes) : ""
        parent.displayPath = String(localized: "Chrome Cache")
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

    private func trimCommandLines(_ s: String) -> [String] {
        s.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func scanHomebrewTools(dirs: [String]) -> (item: CategoryItem?, ownedDirs: Set<String>) {
        var ownedDirs = Set<String>()
        guard let brewPath = locateBinary("brew", in: dirs) else {
            return (nil, ownedDirs)
        }
        let prefix = runCommandCapture(brewPath, ["--prefix"]) ?? "/opt/homebrew"
        let cellar = runCommandCapture(brewPath, ["--cellar"]) ?? "\(prefix)/Cellar"
        let caskroom = "\(prefix)/Caskroom"
        let appMap = appSizeMap()
        var groups: [CategoryItem] = []

        if let out = runCommandCapture(brewPath, ["leaves"]) {
            let items = trimCommandLines(out).map { name -> CategoryItem in
                let keg = (cellar as NSString).appendingPathComponent(name)
                return leaf(name, calculateDirectorySize(at: keg, isDirectory: true), finderPath: keg)
            }.sorted { $0.sizeBytes > $1.sizeBytes }
            if !items.isEmpty {
                groups.append(
                    displayParent(
                        name: "Formulae",
                        label: "Formulae (\(items.count))",
                        icon: "shippingbox.fill",
                        color: .orange,
                        children: items,
                        finderPath: cellar
                    )
                )
            }
        }
        if let out = runCommandCapture(brewPath, ["list", "--cask"]) {
            let items = trimCommandLines(out).map { name -> CategoryItem in
                let caskPath = (caskroom as NSString).appendingPathComponent(name)
                var size = calculateDirectorySize(at: caskPath, isDirectory: true)
                if let appPath = appMap[normalizeString(name)] {
                    size += calculateDirectorySize(at: appPath, isDirectory: true)
                }
                return leaf(name, size, finderPath: appMap[normalizeString(name)] ?? caskPath)
            }.sorted { $0.sizeBytes > $1.sizeBytes }
            if !items.isEmpty {
                groups.append(
                    displayParent(
                        name: "Casks",
                        label: "Casks (\(items.count))",
                        icon: "shippingbox.fill",
                        color: .orange,
                        children: items,
                        finderPath: caskroom
                    )
                )
            }
        }
        ownedDirs.insert((brewPath as NSString).deletingLastPathComponent)
        if dirs.contains("/usr/local/bin") { ownedDirs.insert("/usr/local/bin") }
        guard !groups.isEmpty else { return (nil, ownedDirs) }
        return (
            displayParent(
                name: "Homebrew",
                label: "Homebrew",
                icon: "cup.and.saucer.fill",
                color: .orange,
                children: groups,
                finderPath: prefix
            ),
            ownedDirs
        )
    }

    private func scanMacPortsTools(dirs: [String]) -> (item: CategoryItem?, ownedDirs: Set<String>) {
        var ownedDirs = Set<String>()
        guard let portPath = locateBinary("port", in: dirs) else {
            return (nil, ownedDirs)
        }
        let portBin = (portPath as NSString).deletingLastPathComponent
        ownedDirs.insert(portBin)
        // MacPorts prefix (e.g. /opt/local) is the parent of its bin dir.
        let prefix = (portBin as NSString).deletingLastPathComponent
        let sbin = (prefix as NSString).appendingPathComponent("sbin")
        if dirs.contains(sbin) { ownedDirs.insert(sbin) }
        let software = (prefix as NSString).appendingPathComponent("var/macports/software")
        let distfiles = (prefix as NSString).appendingPathComponent("var/macports/distfiles")
        let build = (prefix as NSString).appendingPathComponent("var/macports/build")

        var portLeaves: [CategoryItem] = []
        var seenPorts = Set<String>()
        if let out = runCommandCapture(portPath, ["installed"]) {
            for raw in out.split(separator: "\n") {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("The following") { continue }
                // Each port line: "name @version_0[+variants] [(active)]" — one leaf per name.
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let nameTok = tokens.first, !nameTok.hasPrefix("@") else { continue }
                let name = String(nameTok)
                if !seenPorts.insert(name).inserted { continue }
                let portDir = (software as NSString).appendingPathComponent(name)
                let size = calculateDirectorySize(at: portDir, isDirectory: true)
                portLeaves.append(leaf(name, size, finderPath: portDir))
            }
        }

        var groups: [CategoryItem] = []
        if !portLeaves.isEmpty {
            portLeaves.sort { $0.sizeBytes > $1.sizeBytes }
            groups.append(
                displayParent(
                    name: "Installed Ports",
                    label: "Installed Ports (\(portLeaves.count))",
                    icon: "shippingbox.fill",
                    color: .teal,
                    children: portLeaves,
                    finderPath: software
                )
            )
        }
        let distfilesSize = calculateDirectorySize(at: distfiles, isDirectory: true)
        if distfilesSize > 0 {
            groups.append(leaf("Distfiles Cache", distfilesSize, finderPath: distfiles, description: LocalizedStringKey("MacPorts distfiles cache")))
        }
        let buildSize = calculateDirectorySize(at: build, isDirectory: true)
        if buildSize > 0 {
            groups.append(leaf("Build Cache", buildSize, finderPath: build, description: LocalizedStringKey("MacPorts build cache")))
        }

        guard !groups.isEmpty else { return (nil, ownedDirs) }
        return (
            displayParent(
                name: "MacPorts",
                label: "MacPorts",
                icon: "shippingbox.fill",
                color: .teal,
                children: groups,
                finderPath: prefix
            ),
            ownedDirs
        )
    }

    private func scanPnpmTools(dirs: [String]) -> (item: CategoryItem?, ownedDirs: Set<String>) {
        var ownedDirs = Set<String>()
        guard let pnpmPath = locateBinary("pnpm", in: dirs) else {
            return (nil, ownedDirs)
        }
        var root: String?
        var pkgs: [(String, Int64)] = []
        if let r = runCommandCapture(pnpmPath, ["root", "-g"]) {
            root = r
            pkgs = sizedPackages(in: r)
        }
        if let gbin = runCommandCapture(pnpmPath, ["config", "get", "global-bin-dir"]), !gbin.isEmpty {
            ownedDirs.insert(gbin)
        }
        guard !pkgs.isEmpty, let r = root else { return (nil, ownedDirs) }
        let children = pkgs.sorted { $0.1 > $1.1 }.map {
            leaf($0.0, $0.1, finderPath: (r as NSString).appendingPathComponent($0.0))
        }
        return (
            displayParent(
                name: "pnpm",
                label: "pnpm (global)",
                icon: "shippingbox.fill",
                color: .teal,
                children: children,
                finderPath: r
            ),
            ownedDirs
        )
    }

    private func scanYarnTools(dirs: [String]) -> (item: CategoryItem?, ownedDirs: Set<String>) {
        var ownedDirs = Set<String>()
        guard let yarnPath = locateBinary("yarn", in: dirs) else {
            return (nil, ownedDirs)
        }
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
        guard !pkgs.isEmpty, let r = root else { return (nil, ownedDirs) }
        let children = pkgs.sorted { $0.1 > $1.1 }.map {
            leaf($0.0, $0.1, finderPath: (r as NSString).appendingPathComponent($0.0))
        }
        return (
            displayParent(
                name: "Yarn",
                label: "Yarn (global)",
                icon: "shippingbox.fill",
                color: .blue,
                children: children,
                finderPath: r
            ),
            ownedDirs
        )
    }

    private func scanCargoTools(dirs: [String]) -> (item: CategoryItem?, ownedDirs: Set<String>) {
        var ownedDirs = Set<String>()
        guard let cargoPath = locateBinary("cargo", in: dirs) else {
            return (nil, ownedDirs)
        }
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
                    size += calculateDirectorySize(
                        at: (cargoBin as NSString).appendingPathComponent(b),
                        isDirectory: false
                    )
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
        guard !crates.isEmpty else { return (nil, ownedDirs) }
        let children = crates.sorted { $0.1 > $1.1 }.map { leaf($0.0, $0.1, finderPath: cargoBin) }
        return (
            displayParent(
                name: "Cargo",
                label: "Cargo",
                icon: "hammer.fill",
                color: .orange,
                children: children,
                finderPath: cargoBin
            ),
            ownedDirs
        )
    }

    private func scanRubyGemsTools(dirs: [String]) -> CategoryItem? {
        guard let gemPath = locateBinary("gem", in: dirs) else { return nil }
        let fm = FileManager.default
        let gpaths = gemPaths(gemPath: gemPath)
        var gemSizes: [String: Int64] = [:]
        var gemLoc: [String: String] = [:]
        for gp in gpaths {
            let gemsDir = (gp as NSString).appendingPathComponent("gems")
            guard let entries = try? fm.contentsOfDirectory(atPath: gemsDir) else { continue }
            for entry in entries {
                guard let name = gemName(from: entry) else { continue }
                let dir = (gemsDir as NSString).appendingPathComponent(entry)
                gemSizes[name, default: 0] += calculateDirectorySize(at: dir, isDirectory: true)
                if gemLoc[name] == nil { gemLoc[name] = dir }
            }
        }
        guard !gemSizes.isEmpty else { return nil }
        let children = gemSizes
            .map { leaf($0.key, $0.value, finderPath: gemLoc[$0.key]) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        return displayParent(
            name: "Ruby Gems",
            label: "Ruby Gems",
            icon: "diamond.fill",
            color: .red,
            children: children,
            finderPath: gpaths.first
        )
    }

    private func scanGoTools(dirs: [String]) -> (item: CategoryItem?, ownedDirs: Set<String>) {
        var ownedDirs = Set<String>()
        guard let goPath = locateBinary("go", in: dirs) else {
            return (nil, ownedDirs)
        }
        let home = NSHomeDirectory()
        var tools: [(String, Int64)] = []
        var goBin: String?
        if let gopath = runCommandCapture(goPath, ["env", "GOPATH"]), !gopath.isEmpty {
            let resolved = gopath.hasPrefix("~/")
                ? (home as NSString).appendingPathComponent(String(gopath.dropFirst(2)))
                : gopath
            let bin = (resolved as NSString).appendingPathComponent("bin")
            for name in binariesInDir(bin) {
                let size = calculateDirectorySize(
                    at: (bin as NSString).appendingPathComponent(name),
                    isDirectory: false
                )
                tools.append((name, size))
            }
            ownedDirs.insert(bin)
            goBin = bin
        }
        guard !tools.isEmpty, let bin = goBin else { return (nil, ownedDirs) }
        let children = tools.sorted { $0.1 > $1.1 }.map {
            leaf($0.0, $0.1, finderPath: (bin as NSString).appendingPathComponent($0.0))
        }
        return (
            displayParent(
                name: "Go",
                label: "Go",
                icon: "shippingbox.fill",
                color: .cyan,
                children: children,
                finderPath: bin
            ),
            ownedDirs
        )
    }

    private func scanPipxTools(dirs: [String]) -> CategoryItem? {
        guard let pipxPath = locateBinary("pipx", in: dirs) else { return nil }
        let home = NSHomeDirectory()
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
            for name in trimCommandLines(out) {
                let size = calculateDirectorySize(
                    at: (venvsDir as NSString).appendingPathComponent(name),
                    isDirectory: true
                )
                apps.append((name, size))
            }
        }
        guard !apps.isEmpty else { return nil }
        let children = apps.sorted { $0.1 > $1.1 }.map {
            leaf($0.0, $0.1, finderPath: (venvsDir as NSString).appendingPathComponent($0.0))
        }
        return displayParent(
            name: "Pipx",
            label: "Pipx",
            icon: "shippingbox.fill",
            color: .indigo,
            children: children,
            finderPath: venvsDir
        )
    }

    private func scanOtherPathTools(dirs: [String], ownedDirs: Set<String>) -> CategoryItem? {
        let home = NSHomeDirectory()
        var otherNodes: [CategoryItem] = []
        for dir in dirs where !ownedDirs.contains(dir) {
            var bins: [(String, Int64)] = []
            for name in binariesInDir(dir) {
                let size = calculateDirectorySize(
                    at: (dir as NSString).appendingPathComponent(name),
                    isDirectory: false
                )
                bins.append((name, size))
            }
            if bins.isEmpty { continue }
            let display = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            let children = bins.sorted { $0.1 > $1.1 }.map {
                leaf($0.0, $0.1, finderPath: (dir as NSString).appendingPathComponent($0.0))
            }
            otherNodes.append(
                displayParent(
                    name: dir,
                    label: display,
                    icon: "folder.fill",
                    color: .blue,
                    children: children,
                    finderPath: dir
                )
            )
        }
        guard !otherNodes.isEmpty else { return nil }
        otherNodes.sort { $0.sizeBytes > $1.sizeBytes }
        return displayParent(
            name: "Other PATH tools",
            label: "Other PATH tools",
            icon: "folder.fill",
            color: .blue,
            children: otherNodes
        )
    }

    // Build the read-only "Installed Tools" tree from non-system PATH tools and their modules.
    private func scanInstalledTools() -> CategoryItem {
        let dirs = nonSystemPathDirs()
        var toolNodes: [CategoryItem] = []
        var ownedDirs = Set<String>()

        let brew = scanHomebrewTools(dirs: dirs)
        ownedDirs.formUnion(brew.ownedDirs)
        if let item = brew.item { toolNodes.append(item) }

        let macports = scanMacPortsTools(dirs: dirs)
        ownedDirs.formUnion(macports.ownedDirs)
        if let item = macports.item { toolNodes.append(item) }

        if let nodeNode = scanNodeInstalls(dirs: dirs, ownedDirs: &ownedDirs) {
            toolNodes.append(nodeNode)
        }

        let pnpm = scanPnpmTools(dirs: dirs)
        ownedDirs.formUnion(pnpm.ownedDirs)
        if let item = pnpm.item { toolNodes.append(item) }

        let yarn = scanYarnTools(dirs: dirs)
        ownedDirs.formUnion(yarn.ownedDirs)
        if let item = yarn.item { toolNodes.append(item) }

        let cargo = scanCargoTools(dirs: dirs)
        ownedDirs.formUnion(cargo.ownedDirs)
        if let item = cargo.item { toolNodes.append(item) }

        if let gems = scanRubyGemsTools(dirs: dirs) { toolNodes.append(gems) }

        let go = scanGoTools(dirs: dirs)
        ownedDirs.formUnion(go.ownedDirs)
        if let item = go.item { toolNodes.append(item) }

        if let pipx = scanPipxTools(dirs: dirs) { toolNodes.append(pipx) }
        if let other = scanOtherPathTools(dirs: dirs, ownedDirs: ownedDirs) {
            toolNodes.append(other)
        }

        let coveredPaths = homeDirectoryEntryPaths()
        let filteredToolNodes = filterHomeCoveredNodes(toolNodes, coveredPaths: coveredPaths)
        return displayParent(
            name: "Installed Tools",
            label: "Installed Tools",
            icon: "terminal.fill",
            color: .primary,
            note: "Read Only",
            children: filteredToolNodes
        )
    }

    private func homeDirectoryEntries() -> [String] {
        let home = NSHomeDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: home) else {
            return []
        }
        return entries.filter { entry in
            let lower = entry.lowercased()
            if Self.homeSystemEntries.contains(lower) { return false }
            if lower.hasPrefix("icloud") { return false }
            return true
        }
    }

    private func scanHomeDirectoryEntry(_ entry: String) -> CategoryItem? {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let fullPath = (home as NSString).appendingPathComponent(entry)
        var entryIsDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &entryIsDir) else { return nil }

        let bytes = calculateDirectorySize(at: fullPath, isDirectory: entryIsDir.boolValue)
        let lowerEntry = entry.lowercased()
        let icon: String
        let color: Color
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

        let children: [CategoryItem]?
        if entryIsDir.boolValue {
            children = scanHomeEntryChildren(for: fullPath, parentSize: bytes)
        } else {
            children = nil
        }

        return displayItem(
            name: entry,
            label: "~/\(entry)",
            icon: icon,
            color: color,
            children: children,
            sizeBytes: bytes,
            finderPath: fullPath,
            description: Self.homeEntryDescriptions[lowerEntry].map { LocalizedStringKey($0) }
        )
    }

    // For known tool-environment roots directly under ~, return expandable children
    // (individual venvs / conda envs / pipx+uv under ~/.local). Nil keeps the entry flat.
    private func scanHomeEntryChildren(for fullPath: String, parentSize: Int64) -> [CategoryItem]? {
        let name = (fullPath as NSString).lastPathComponent.lowercased()
        if [".virtualenvs", ".venvs", ".envs", "venvs"].contains(name) {
            let kids = scanVenvChildren(in: fullPath, fallbackDescription: LocalizedStringKey("Python venv"))
            return kids.isEmpty ? nil : kids
        }
        if ["miniconda3", "anaconda3", "miniforge3", "mambaforge3",
            "miniforge", "mambaforge", "miniconda", "anaconda"].contains(name) {
            let kids = scanCondaEnvChildren(root: fullPath, rootSize: parentSize)
            return kids.isEmpty ? nil : kids
        }
        if name == ".local" {
            let kids = scanLocalChildren(in: fullPath)
            return kids.isEmpty ? nil : kids
        }
        return nil
    }

    // Each subdirectory of a venv root is one virtual environment. pyvenv.cfg is preferred;
    // dirs without it (old virtualenv) are still treated as venvs.
    private func scanVenvChildren(in root: String, fallbackDescription: LocalizedStringKey? = nil) -> [CategoryItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var nodes: [CategoryItem] = []
        for entry in entries {
            if entry.hasPrefix(".") { continue }
            let venvPath = (root as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: venvPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let size = calculateDirectorySize(at: venvPath, isDirectory: true)
            let desc = pythonVersionDescription(venvPath: venvPath) ?? fallbackDescription
            nodes.append(leaf(entry, size, finderPath: venvPath, description: desc))
        }
        return nodes.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // Read the Python version from a venv's pyvenv.cfg (`version`, then `version_info`).
    private func pythonVersionDescription(venvPath: String) -> LocalizedStringKey? {
        let cfg = (venvPath as NSString).appendingPathComponent("pyvenv.cfg")
        guard let content = try? String(contentsOfFile: cfg, encoding: .utf8) else { return nil }
        var version: String?
        var versionInfo: String?
        for raw in content.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if key == "version" { version = val }
            else if key == "version_info" { versionInfo = val }
        }
        if let v = version, !v.isEmpty {
            let key: LocalizedStringKey = "Python \(v)"
            return key
        }
        if let v = versionInfo, !v.isEmpty {
            let key: LocalizedStringKey = "Python \(v)"
            return key
        }
        return nil
    }

    // Conda envs: the base environment + each subdir of envs/ + the pkgs package cache.
    // Sizes are subsets of the conda root total (base = root - envs - pkgs) so nothing is
    // double-counted against the home entry's own size. Envs whose real path is outside
    // this root are skipped — they already appear as their own home entry.
    private func scanCondaEnvChildren(root: String, rootSize: Int64) -> [CategoryItem] {
        let fm = FileManager.default
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let envsDir = (root as NSString).appendingPathComponent("envs")
        var envNodes: [CategoryItem] = []
        var envsTotal: Int64 = 0
        if let entries = try? fm.contentsOfDirectory(atPath: envsDir) {
            for entry in entries {
                if entry.hasPrefix(".") { continue }
                let envPath = (envsDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: envPath, isDirectory: &isDir), isDir.boolValue else { continue }
                let resolved = URL(fileURLWithPath: envPath).resolvingSymlinksInPath().path
                if resolved != resolvedRoot && !resolved.hasPrefix(resolvedRoot + "/") {
                    continue
                }
                let size = calculateDirectorySize(at: envPath, isDirectory: true)
                envsTotal += size
                envNodes.append(leaf(entry, size, finderPath: envPath, description: LocalizedStringKey("Conda environment")))
            }
        }
        let pkgsPath = (root as NSString).appendingPathComponent("pkgs")
        let pkgsSize = calculateDirectorySize(at: pkgsPath, isDirectory: true)
        var children: [CategoryItem] = []
        let baseSize = max(0, rootSize - envsTotal - pkgsSize)
        if baseSize > 0 {
            children.append(leaf("base", baseSize, finderPath: root, description: LocalizedStringKey("Conda base environment")))
        }
        children.append(contentsOf: envNodes.sorted { $0.sizeBytes > $1.sizeBytes })
        if pkgsSize > 0 {
            children.append(leaf("pkgs", pkgsSize, finderPath: pkgsPath, description: LocalizedStringKey("Conda package cache")))
        }
        return children
    }

    // ~/.local is composite: keep the parent's full size and only break out Pipx + uv tools.
    private func scanLocalChildren(in root: String) -> [CategoryItem] {
        var groups: [CategoryItem] = []

        var pipxLeaves: [CategoryItem] = []
        var pipxFinder: String?
        var seenPipx = Set<String>()
        let pipxVenvDirs = [
            (root as NSString).appendingPathComponent("pipx/venvs"),
            (root as NSString).appendingPathComponent("share/pipx/venvs")
        ]
        for dir in pipxVenvDirs {
            for kid in scanVenvChildren(in: dir, fallbackDescription: LocalizedStringKey("Pipx tool")) {
                if !seenPipx.insert(kid.name).inserted { continue }
                pipxLeaves.append(kid)
                if pipxFinder == nil { pipxFinder = dir }
            }
        }
        if !pipxLeaves.isEmpty {
            pipxLeaves.sort { $0.sizeBytes > $1.sizeBytes }
            groups.append(
                displayParent(
                    name: "Pipx",
                    label: "Pipx (\(pipxLeaves.count))",
                    icon: "shippingbox.fill",
                    color: .indigo,
                    children: pipxLeaves,
                    finderPath: pipxFinder
                )
            )
        }

        let uvToolsDir = (root as NSString).appendingPathComponent("share/uv/tools")
        let uvLeaves = scanVenvChildren(in: uvToolsDir, fallbackDescription: LocalizedStringKey("uv tool"))
        if !uvLeaves.isEmpty {
            groups.append(
                displayParent(
                    name: "uv Tools",
                    label: "uv Tools (\(uvLeaves.count))",
                    icon: "shippingbox.fill",
                    color: .purple,
                    children: uvLeaves,
                    finderPath: uvToolsDir
                )
            )
        }
        return groups
    }

    // Enumerate every non-system entry (file or folder, hidden or visible) directly under the
    // home directory -- especially the dot-prefixed tool/data folders such as .ollama, .cargo,
    // .gradle. Display-only: each row reveals its location in Finder via the magnifying glass;
    // nothing here is ever cleaned.
    private func scanHomeDirectory() -> CategoryItem? {
        var childItems = homeDirectoryEntries().compactMap(scanHomeDirectoryEntry)
        guard !childItems.isEmpty else { return nil }
        childItems.sort { $0.sizeBytes > $1.sizeBytes }
        return displayParent(
            name: "Home Directory",
            label: "Home Directory",
            icon: "folder.fill",
            color: .blue,
            note: "Non-system Items",
            children: childItems
        )
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
            childItems.append(displayItem(name: folder, label: displayPath, icon: "folder.fill", color: .blue, note: describeDirectoryContents(at: fullPath), sizeBytes: sizeBytes, finderPath: fullPath))
        }

        guard !childItems.isEmpty else { return nil }
        childItems.sort { $0.sizeBytes > $1.sizeBytes }

        return displayParent(name: "Installed App Data", label: basePath, icon: "folder.fill", color: .blue, note: "App Data", children: childItems, finderPath: expandedBasePath)
    }


    // Prefer on-disk allocation over logical size so sparse VM images
    // (OrbStack / Colima / Docker Desktop) report real usage, not capacity.
    private static let diskUsageResourceKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    private static func diskUsageBytes(from values: URLResourceValues) -> Int64? {
        if let size = values.totalFileAllocatedSize { return Int64(size) }
        if let size = values.fileAllocatedSize { return Int64(size) }
        if let size = values.fileSize { return Int64(size) }
        return nil
    }

    func calculateDirectorySize(at path: String, isDirectory: Bool) -> Int64 {
        let url = URL(fileURLWithPath: path)
        if !isDirectory {
            if let values = try? url.resourceValues(forKeys: Set(Self.diskUsageResourceKeys)),
               let size = Self.diskUsageBytes(from: values) {
                return size
            }
            return 0
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Self.diskUsageResourceKeys + [.isDirectoryKey]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: Set(Self.diskUsageResourceKeys + [.isDirectoryKey])),
               let isDir = values.isDirectory, !isDir,
               let size = Self.diskUsageBytes(from: values) {
                totalSize += size
            }
        }
        return totalSize
    }

}
