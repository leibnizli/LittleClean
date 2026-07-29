import SwiftUI

// LocalizedStringKey is an immutable value but does not declare Sendable in SwiftUI.
// CategoryItem crosses queues only as a value snapshot.
nonisolated struct CategoryItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let pathDescription: String
    let iconName: String
    let iconColor: Color
    var sizeBytes: Int64
    var sizeString: String
    let rule: CleanRule
    var children: [CategoryItem]? = nil
    // Read-only informational node: no checkbox, never cleaned (Finder reveal via finderPath)
    var isSelected: Bool = true
    // Real filesystem location to reveal in Finder (display-only nodes use a label as pathDescription)
    var isDisplayOnly: Bool = false
    var finderPath: String? = nil
    // Override label shown in the Path column (used to show ancestor context in search results)
    var displayPath: String? = nil
    // Short description shown in the "Note" column (what this dir/tool is)
    var description: LocalizedStringKey? = nil
}

nonisolated enum SelectionState {
    case checked, unchecked, mixed

    var symbolName: String {
        switch self {
        case .checked: return "checkmark.square.fill"
        case .unchecked: return "square"
        case .mixed: return "minus.square.fill"
        }
    }
}
