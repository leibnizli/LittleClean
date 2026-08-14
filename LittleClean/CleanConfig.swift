import SwiftUI

nonisolated enum ScanMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case uninstallApps
    case safeCleanup
    case deepAnalysis

    var id: String { rawValue }

    var allowsCleaning: Bool {
        self != .deepAnalysis
    }
}

nonisolated enum CleanType: Equatable, Sendable {
    case none
    case deleteDirectory        // clear contents, keep the folder (caches)
    case deleteDirectoryTree    // remove the folder entirely (leftovers)
    case deletePaths([String])
    case trashPaths([String])   // move an app and its related files to Trash
    case runCommand(executable: String, args: [String])
}

// LocalizedStringKey is immutable but does not declare Sendable in SwiftUI.
nonisolated struct CleanRule: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let pathDescription: String // e.g. "~/Library/Caches"
    let iconName: String
    let iconColor: Color
    var cleanType: CleanType = .deleteDirectory
    var note: LocalizedStringKey? = nil
    var isDynamicSimulatorRule: Bool = false
    var isDynamicLeftoversRule: Bool = false
    var isDynamicHomeCleanupRule: Bool = false
    var isDynamicUnavailableSimulatorRule: Bool = false
    var isDynamicContainerLeftoversRule: Bool = false
    var isDynamicExtensionLeftoversRule: Bool = false
    var isDynamicChromeCacheRule: Bool = false
    var isCheckboxHidden: Bool = false
    var scanMode: ScanMode = .safeCleanup
}

nonisolated struct CleanConfig {
    static let defaultRules: [CleanRule] = [
        CleanRule(
            name: "Chrome Cache",
            pathDescription: "~/Library/Application Support/Google/Chrome",
            iconName: "globe",
            iconColor: .orange,
            note: "Chrome Cache",
            isDynamicChromeCacheRule: true,
            isCheckboxHidden: true,
            scanMode: .safeCleanup
        ),
        CleanRule(name: "System Logs", pathDescription: "~/Library/Logs", iconName: "doc.text.fill", iconColor: .blue, note: "System Logs"),
        CleanRule(name: "System Trash", pathDescription: "~/.Trash", iconName: "trash.fill", iconColor: .red, note: "System Trash"),
        CleanRule(name: "Xcode DerivedData", pathDescription: "~/Library/Developer/Xcode/DerivedData", iconName: "hammer.fill", iconColor: .purple, note: "Xcode DerivedData"),
        CleanRule(
            name: "Xcode Archives",
            pathDescription: "~/Library/Developer/Xcode/Archives",
            iconName: "archivebox.fill",
            iconColor: .indigo,
            note: "Xcode Archives",
            scanMode: .deepAnalysis
        ),
        CleanRule(name: "iOS Simulator Caches", pathDescription: "~/Library/Developer/CoreSimulator/Caches", iconName: "iphone", iconColor: .teal, note: "iOS Simulator Caches"),
        CleanRule(
            name: "Simulator Devices by Version",
            pathDescription: "~/Library/Developer/CoreSimulator/Devices",
            iconName: "iphone.badge.play",
            iconColor: .purple,
            isDynamicSimulatorRule: true,
            isCheckboxHidden: true,
            scanMode: .deepAnalysis
        ),
        CleanRule(
            name: "Unavailable Simulators",
            pathDescription: "~/Library/Developer/CoreSimulator/Devices",
            iconName: "iphone.slash",
            iconColor: .red,
            isDynamicUnavailableSimulatorRule: true,
            isCheckboxHidden: true,
            scanMode: .safeCleanup
        ),
        CleanRule(
            name: "Uninstalled App Leftovers",
            pathDescription: "~/Library/Application Support",
            iconName: "folder.fill",
            iconColor: .pink,
            isDynamicLeftoversRule: true,
            isCheckboxHidden: true,
            scanMode: .safeCleanup
        ),
        CleanRule(
            name: "Container Leftovers",
            pathDescription: "~/Library/Containers",
            iconName: "shippingbox.fill",
            iconColor: .pink,
            isDynamicContainerLeftoversRule: true,
            isCheckboxHidden: true,
            scanMode: .safeCleanup
        ),
        CleanRule(
            name: "Extension Leftovers",
            pathDescription: "Extension Leftovers",
            iconName: "puzzlepiece.extension.fill",
            iconColor: .pink,
            isDynamicExtensionLeftoversRule: true,
            isCheckboxHidden: true,
            scanMode: .safeCleanup
        ),
        CleanRule(name: "Saved App State", pathDescription: "~/Library/Saved Application State", iconName: "clock.arrow.circlepath", iconColor: .mint, note: "Saved App State"),
        CleanRule(
            name: "Home Directory Cleanup",
            pathDescription: "~",
            iconName: "folder.fill",
            iconColor: .blue,
            note: "Home Cleanup",
            isDynamicHomeCleanupRule: true,
            isCheckboxHidden: true
        )
    ]
}
