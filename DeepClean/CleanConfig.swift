import SwiftUI

enum CleanType {
    case deleteDirectory
    case runCommand(executable: String, args: [String])
}

struct CleanRule: Identifiable {
    let id = UUID()
    let name: String
    let pathDescription: String // e.g. "~/Library/Caches"
    let iconName: String
    let iconColor: Color
    var cleanType: CleanType = .deleteDirectory
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
            name: "Unavailable Simulators",
            pathDescription: "~/Library/Developer/CoreSimulator/Devices",
            iconName: "iphone.slash",
            iconColor: .gray,
            cleanType: .runCommand(executable: "/usr/bin/xcrun", args: ["simctl", "delete", "unavailable"])
        )
    ]
}
