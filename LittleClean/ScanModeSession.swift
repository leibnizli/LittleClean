import Combine
import SwiftUI

@MainActor
final class ScanModeSession: ObservableObject {
    let mode: ScanMode

    @Published var categories: [CategoryItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var sortOrder: [KeyPathComparator<CategoryItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse)
    ]
    @Published var searchText = ""
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var isLoadingDetails = false
    @Published var hasLoaded = false

    var scanToken = 0
    var detailsLoadToken = 0

    init(mode: ScanMode) {
        self.mode = mode
    }

    var isBusy: Bool {
        isScanning || isLoadingDetails || isCleaning
    }

    var displayedCategories: [CategoryItem] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        let base: [CategoryItem]
        if trimmedSearch.isEmpty {
            base = categories
        } else if mode == .uninstallApps {
            base = Self.filterUninstallApplications(categories, query: trimmedSearch)
        } else {
            base = Self.flatFilteredLeaves(categories, query: trimmedSearch)
        }
        var result = base.sorted(using: sortOrder)
        for index in result.indices {
            result[index].children?.sort(using: sortOrder)
        }
        return result
    }

    var selectedTotalBytes: Int64 {
        ContentViewModel.collectCleanableSelected(
            from: categories,
            selectedIDs: selectedIDs
        ).reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedItemNames: [String] {
        categories
            .filter { item in
                if item.isAtomicSelection {
                    return ContentViewModel.uninstallDetailIDs(item)
                        .contains { selectedIDs.contains($0) }
                }
                return selectedIDs.contains(item.id)
            }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func filterUninstallApplications(
        _ items: [CategoryItem],
        query: String
    ) -> [CategoryItem] {
        let loweredQuery = query.lowercased()
        return items.filter { item in
            item.name.lowercased().contains(loweredQuery)
                || item.pathDescription.lowercased().contains(loweredQuery)
                || (item.children ?? []).contains {
                    $0.pathDescription.lowercased().contains(loweredQuery)
                }
        }
    }

    private static func flatFilteredLeaves(
        _ items: [CategoryItem],
        query: String
    ) -> [CategoryItem] {
        let query = query.lowercased()
        var result: [CategoryItem] = []
        func walk(_ items: [CategoryItem], ancestors: [String]) {
            for item in items {
                if let children = item.children, !children.isEmpty {
                    walk(children, ancestors: ancestors + [item.pathDescription])
                } else {
                    let context = (ancestors + [item.pathDescription]).joined(separator: " / ")
                    if item.pathDescription.lowercased().contains(query) {
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
}
