import AppKit
import Combine
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var totalBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    @Published var usedBytes: Int64 = 0
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var isLoadingDetails = false
    @Published var newVersionURL: String?
    @Published var categories: [CategoryItem] = []
    @Published var sortOrder: [KeyPathComparator<CategoryItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse)
    ]
    @Published var selectedIDs: Set<UUID> = []
    @Published var searchText = ""

    private let scanner: FileSystemScanner
    private let cleaner: Cleaner
    private let updateChecker: UpdateChecker
    private var detailsLoadToken = 0

    init(
        scanner: FileSystemScanner = FileSystemScanner(),
        cleaner: Cleaner = Cleaner(),
        updateChecker: UpdateChecker = UpdateChecker()
    ) {
        self.scanner = scanner
        self.cleaner = cleaner
        self.updateChecker = updateChecker
    }

    var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(Double(usedBytes) / Double(totalBytes) * 100)
    }

    var selectedTotalBytes: Int64 {
        collectCleanableSelected(from: categories).reduce(0) { $0 + $1.sizeBytes }
    }

    var displayedCategories: [CategoryItem] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? categories
            : flatFilteredLeaves(categories, query: searchText)
        var result = base.sorted(using: sortOrder)
        for index in result.indices {
            result[index].children?.sort(using: sortOrder)
        }
        return result
    }

    func performScan() {
        isScanning = true
        isLoadingDetails = false
        loadRealDiskSpace()

        let scanner = scanner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let foundCategories = scanner.scanCategories()
            DispatchQueue.main.async {
                guard let self else { return }
                self.categories = foundCategories
                self.selectedIDs = []
                self.isScanning = false
                self.loadDetails()
            }
        }
    }

    func checkForUpdates() {
        updateChecker.checkForNewVersion { [weak self] url in
            DispatchQueue.main.async {
                self?.newVersionURL = url
            }
        }
    }

    func performCleanSelected() {
        let items = collectCleanableSelected(from: categories)
        guard !items.isEmpty else { return }
        clean(items, clearingAllSelection: true)
    }

    func cleanSingleItem(_ item: CategoryItem) {
        var items: [CategoryItem] = []
        func collectLeaves(_ node: CategoryItem) {
            if let children = node.children, !children.isEmpty {
                children.forEach(collectLeaves)
            } else {
                items.append(node)
            }
        }
        collectLeaves(item)
        guard !items.isEmpty else { return }
        clean(items, clearingAllSelection: false)
    }

    func isCleanable(_ item: CategoryItem) -> Bool {
        if item.rule.cleanType != .none { return true }
        if let children = item.children {
            return children.contains { isCleanable($0) }
        }
        return false
    }

    func selectionState(for item: CategoryItem) -> SelectionState {
        if let children = item.children, !children.isEmpty {
            let leaves = leafIDs(item)
            guard !leaves.isEmpty else { return .unchecked }
            let selected = leaves.intersection(selectedIDs).count
            if selected == 0 { return .unchecked }
            if selected == leaves.count { return .checked }
            return .mixed
        }
        return selectedIDs.contains(item.id) ? .checked : .unchecked
    }

    func toggleSelection(_ item: CategoryItem) {
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

    func openInFinder(pathDescription: String) {
        let expandedPath = NSString(string: pathDescription).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else { return }
        if expandedPath.hasSuffix(".app") || !isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func loadDetails() {
        detailsLoadToken += 1
        let token = detailsLoadToken
        isLoadingDetails = true
        let scanner = scanner

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detailItems = scanner.scanDetails()
            DispatchQueue.main.async {
                guard let self, token == self.detailsLoadToken, !self.isScanning else { return }
                let existingNames = Set(self.categories.filter(\.isDisplayOnly).map(\.name))
                for detailItem in detailItems where !existingNames.contains(detailItem.name) {
                    if detailItem.pathDescription == "~/Library/Application Support",
                       let index = self.categories.firstIndex(where: {
                           $0.pathDescription == detailItem.pathDescription && $0.children != nil
                       }),
                       let detailChildren = detailItem.children {
                        let current = self.categories[index]
                        let children = (current.children ?? []) + detailChildren
                        let totalBytes = children.reduce(0) { $0 + $1.sizeBytes }
                        let rule = CleanRule(
                            name: "Application Support",
                            pathDescription: detailItem.pathDescription,
                            iconName: "folder.fill",
                            iconColor: .blue,
                            cleanType: .none,
                            note: "App Data",
                            isCheckboxHidden: true
                        )
                        self.categories[index] = CategoryItem(
                            name: rule.name,
                            pathDescription: rule.pathDescription,
                            iconName: rule.iconName,
                            iconColor: rule.iconColor,
                            sizeBytes: totalBytes,
                            sizeString: formatBytes(totalBytes),
                            rule: rule,
                            children: children
                        )
                    } else {
                        self.categories.append(detailItem)
                    }
                }
                self.isLoadingDetails = false
            }
        }
    }

    private func clean(_ items: [CategoryItem], clearingAllSelection: Bool) {
        let cleanedIDs = Set(items.map { $0.id })
        let snapshot = categories
        let cleaner = cleaner
        isCleaning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let updated = cleaner.clean(items, in: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.categories = updated
                self.isCleaning = false
                if clearingAllSelection {
                    self.selectedIDs = []
                } else {
                    self.selectedIDs.subtract(cleanedIDs)
                }
                self.loadRealDiskSpace()
            }
        }
    }

    private func flatFilteredLeaves(_ items: [CategoryItem], query: String) -> [CategoryItem] {
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

    private func loadRealDiskSpace() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let total = values.volumeTotalCapacity,
               let free = values.volumeAvailableCapacityForImportantUsage {
                totalBytes = Int64(total)
                freeBytes = Int64(free)
                usedBytes = max(0, totalBytes - freeBytes)
            }
        } catch {
            print("Failed to load real disk space: \(error)")
        }
    }
}
