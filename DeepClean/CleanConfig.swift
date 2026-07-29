import SwiftUI

enum CleanType: Equatable {
    case none
    case deleteDirectory        // clear contents, keep the folder (caches)
    case deleteDirectoryTree    // remove the folder entirely (leftovers)
    case deletePaths([String])
    case runCommand(executable: String, args: [String])
}

struct CleanRule: Identifiable {
    let id = UUID()
    let name: String
    let pathDescription: String // e.g. "~/Library/Caches"
    let iconName: String
    let iconColor: Color
    var cleanType: CleanType = .deleteDirectory
    var note: String? = nil
    var isDynamicSimulatorRule: Bool = false
    var isDynamicLeftoversRule: Bool = false
    var isDynamicHomeCleanupRule: Bool = false
    var isDynamicUnavailableSimulatorRule: Bool = false
    var isCheckboxHidden: Bool = false
}

struct CleanConfig {
    static let defaultRules: [CleanRule] = [
        CleanRule(name: "App Caches", pathDescription: "~/Library/Caches", iconName: "archivebox.fill", iconColor: .orange, note: "App Caches"),
        CleanRule(name: "System Logs", pathDescription: "~/Library/Logs", iconName: "doc.text.fill", iconColor: .blue, note: "System Logs"),
        CleanRule(name: "System Trash", pathDescription: "~/.Trash", iconName: "trash.fill", iconColor: .red, note: "System Trash"),
        CleanRule(name: "Xcode DerivedData", pathDescription: "~/Library/Developer/Xcode/DerivedData", iconName: "hammer.fill", iconColor: .purple, note: "Xcode DerivedData"),
        CleanRule(name: "Xcode Archives", pathDescription: "~/Library/Developer/Xcode/Archives", iconName: "archivebox", iconColor: .indigo, note: "Xcode Archives"),
        CleanRule(name: "iOS Simulator Caches", pathDescription: "~/Library/Developer/CoreSimulator/Caches", iconName: "iphone", iconColor: .teal, note: "iOS Simulator Caches"),
        CleanRule(
            name: "Simulator Devices by Version",
            pathDescription: "~/Library/Developer/CoreSimulator/Devices",
            iconName: "iphone.badge.play",
            iconColor: .purple,
            isDynamicSimulatorRule: true
        ),
        CleanRule(
            name: "Unavailable Simulators",
            pathDescription: "~/Library/Developer/CoreSimulator/Devices",
            iconName: "iphone.slash",
            iconColor: .red,
            isDynamicUnavailableSimulatorRule: true
        ),
        CleanRule(
            name: "Uninstalled App Leftovers",
            pathDescription: "~/Library/Application Support",
            iconName: "folder.badge.minus",
            iconColor: .pink,
            isDynamicLeftoversRule: true
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
