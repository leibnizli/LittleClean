import SwiftUI

enum CleanType {
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
    var isDynamicHomeCacheRule: Bool = false
    var isDynamicHomeLeftoversRule: Bool = false
}

struct CleanConfig {
    static let defaultRules: [CleanRule] = [
        CleanRule(name: "App Caches", pathDescription: "~/Library/Caches", iconName: "archivebox.fill", iconColor: .orange),
        CleanRule(name: "System Logs", pathDescription: "~/Library/Logs", iconName: "doc.text.fill", iconColor: .blue),
        CleanRule(name: "System Trash", pathDescription: "~/.Trash", iconName: "trash.fill", iconColor: .red),
        CleanRule(name: "Xcode DerivedData", pathDescription: "~/Library/Developer/Xcode/DerivedData", iconName: "hammer.fill", iconColor: .purple),
        CleanRule(name: "Xcode Archives", pathDescription: "~/Library/Developer/Xcode/Archives", iconName: "archivebox", iconColor: .indigo),
        CleanRule(name: "iOS Simulator Caches", pathDescription: "~/Library/Developer/CoreSimulator/Caches", iconName: "iphone", iconColor: .teal),
        CleanRule(
            name: "Simulator Devices by Version",
            pathDescription: "~/Library/Developer/CoreSimulator/Devices",
            iconName: "iphone.badge.play",
            iconColor: .purple,
            isDynamicSimulatorRule: true
        ),
        CleanRule(
            name: "Uninstalled App Leftovers",
            pathDescription: "~/Library/Application Support",
            iconName: "folder.badge.minus",
            iconColor: .pink,
            isDynamicLeftoversRule: true
        ),
        CleanRule(name: "Saved App State", pathDescription: "~/Library/Saved Application State", iconName: "clock.arrow.circlepath", iconColor: .mint),
        CleanRule(
            name: "Home Tool Caches",
            pathDescription: "~",
            iconName: "shippingbox.fill",
            iconColor: .orange,
            isDynamicHomeCacheRule: true
        ),
        CleanRule(
            name: "Home Directory Leftovers",
            pathDescription: "~",
            iconName: "folder.badge.minus",
            iconColor: .pink,
            isDynamicHomeLeftoversRule: true
        )
    ]
}
