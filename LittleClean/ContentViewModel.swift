import AppKit
import Combine
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
    private struct ScanSnapshot {
        let categories: [CategoryItem]
        let needsFullDiskAccess: Bool
    }

    @Published var totalBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    @Published var usedBytes: Int64 = 0
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var isLoadingDetails = false
    @Published var newVersionURL: String?
    @Published var cleaningErrorMessage: String?
    @Published var needsFullDiskAccess = false
    @Published var categories: [CategoryItem] = []
    @Published var sortOrder: [KeyPathComparator<CategoryItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse)
    ]
    @Published var selectedIDs: Set<UUID> = []
    @Published var searchText = ""
    @Published var scanMode: ScanMode = .uninstallApps

    private let scanner: FileSystemScanner
    private let cleaner: Cleaner
    private let updateChecker: UpdateChecker
    private var scanCache: [ScanMode: ScanSnapshot] = [:]
    private var scanToken = 0
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

    var selectedItemNames: [String] {
        categories
            .filter { item in
                if item.isAtomicSelection {
                    return uninstallDetailIDs(item).contains { selectedIDs.contains($0) }
                }
                return selectedIDs.contains(item.id)
            }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var displayedCategories: [CategoryItem] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        let base: [CategoryItem]
        if trimmedSearch.isEmpty {
            base = categories
        } else if scanMode == .uninstallApps {
            base = filterUninstallApplications(categories, query: trimmedSearch)
        } else {
            base = flatFilteredLeaves(categories, query: trimmedSearch)
        }
        var result = base.sorted(using: sortOrder)
        for index in result.indices {
            result[index].children?.sort(using: sortOrder)
        }
        return result
    }

    func selectScanMode(_ mode: ScanMode) {
        guard mode != scanMode else { return }
        scanMode = mode
        activateScanMode()
    }

    private func activateScanMode() {
        scanToken += 1
        detailsLoadToken += 1
        isScanning = false
        isLoadingDetails = false
        selectedIDs = []

        if let snapshot = scanCache[scanMode] {
            categories = snapshot.categories
            needsFullDiskAccess = snapshot.needsFullDiskAccess
            loadRealDiskSpace()
        } else {
            performScan()
        }
    }

    func performScan() {
        scanToken += 1
        let token = scanToken
        let mode = scanMode
        detailsLoadToken += 1
        scanCache[mode] = nil
        isScanning = true
        isLoadingDetails = false
        categories = []
        selectedIDs = []
        loadRealDiskSpace()

        let scanner = scanner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.scanCategories(mode: mode)
            DispatchQueue.main.async {
                guard let self, token == self.scanToken, mode == self.scanMode else { return }
                self.categories = result.categories
                self.needsFullDiskAccess = result.containerAccessDenied
                self.isScanning = false
                if mode == .deepAnalysis {
                    self.loadDetails(for: token)
                } else if mode == .uninstallApps {
                    self.loadUninstallEnrichment(for: token)
                } else {
                    self.cacheCurrentScan(for: mode)
                }
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
        guard scanMode.allowsCleaning else { return }
        let items = collectCleanableSelected(from: categories)
        guard !items.isEmpty else { return }
        clean(items, clearingAllSelection: true)
    }

    func cleanSingleItem(_ item: CategoryItem) {
        guard scanMode.allowsCleaning else { return }
        if item.isAtomicSelection {
            clean([item], clearingAllSelection: false)
            return
        }
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
        guard scanMode.allowsCleaning else { return false }
        if item.isSelectionDetail { return true }
        if item.rule.cleanType != .none { return true }
        if let children = item.children {
            return children.contains { isCleanable($0) }
        }
        return false
    }

    func selectionState(for item: CategoryItem) -> SelectionState {
        if item.isAtomicSelection {
            let details = uninstallDetailIDs(item)
            guard !details.isEmpty else { return .unchecked }
            let selectedCount = details.filter { selectedIDs.contains($0) }.count
            if selectedCount == 0 { return .unchecked }
            if selectedCount == details.count { return .checked }
            return .mixed
        }
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
        if item.isAtomicSelection {
            let details = Set(uninstallDetailIDs(item))
            guard !details.isEmpty else { return }
            if details.isSubset(of: selectedIDs) {
                selectedIDs.subtract(details)
            } else {
                selectedIDs.formUnion(details)
            }
            return
        }
        if item.isSelectionDetail {
            guard !item.isRequiredSelectionDetail else { return }
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
                if let parent = categories.first(where: {
                    ($0.children ?? []).contains { $0.id == item.id }
                }),
                   let requiredID = parent.children?.first(where: {
                       $0.isRequiredSelectionDetail
                   })?.id {
                    selectedIDs.insert(requiredID)
                }
            }
            return
        }
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
        if expandedPath.hasSuffix(".app") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // activateFileViewerSelecting explicitly reveals the item in Finder instead of "executing" it.
            // This prevents LaunchServices from incorrectly treating sandboxed containers 
            // or uninstalled app leftovers as documents that need to be launched.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadDetails(for scanToken: Int) {
        detailsLoadToken += 1
        let token = detailsLoadToken
        isLoadingDetails = true
        let scanner = scanner

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detailResult = scanner.scanDetails()
            DispatchQueue.main.async {
                guard let self,
                      token == self.detailsLoadToken,
                      scanToken == self.scanToken,
                      self.scanMode == .deepAnalysis,
                      !self.isScanning else { return }
                self.needsFullDiskAccess = self.needsFullDiskAccess
                    || detailResult.containerAccessDenied
                let detailItems = detailResult.items
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
                            children: children,
                            isDisplayOnly: true,
                            finderPath: detailItem.finderPath ?? detailItem.pathDescription
                        )
                    } else {
                        self.categories.append(detailItem)
                    }
                }
                self.isLoadingDetails = false
                self.cacheCurrentScan(for: .deepAnalysis)
            }
        }
    }

    private func loadUninstallEnrichment(for scanToken: Int) {
        detailsLoadToken += 1
        let token = detailsLoadToken
        let snapshot = categories
        let scanner = scanner
        isLoadingDetails = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enrichment = scanner.enrichUninstallApplications(snapshot)
            DispatchQueue.main.async {
                guard let self,
                      token == self.detailsLoadToken,
                      scanToken == self.scanToken,
                      self.scanMode == .uninstallApps,
                      !self.isScanning else { return }
                let selectedPaths = self.selectedUninstallDetailPaths()
                self.categories = enrichment.items
                self.needsFullDiskAccess = self.needsFullDiskAccess || enrichment.accessDenied
                self.restoreUninstallSelection(matching: selectedPaths)
            }

            for item in enrichment.items {
                let measured = scanner.measureUninstallApplication(item)
                DispatchQueue.main.async {
                    guard let self,
                          token == self.detailsLoadToken,
                          scanToken == self.scanToken,
                          self.scanMode == .uninstallApps,
                          !self.isScanning else { return }
                    let selectedPaths = self.selectedUninstallDetailPaths()
                    if let index = self.categories.firstIndex(where: {
                        $0.pathDescription == measured.pathDescription
                    }) {
                        self.categories[index] = measured
                        self.restoreUninstallSelection(matching: selectedPaths)
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self,
                      token == self.detailsLoadToken,
                      scanToken == self.scanToken,
                      self.scanMode == .uninstallApps,
                      !self.isScanning else { return }
                self.isLoadingDetails = false
                self.cacheCurrentScan(for: .uninstallApps)
            }
        }
    }

    private func selectedUninstallDetailPaths() -> Set<String> {
        Set(
            categories.flatMap { item in
                (item.children ?? [])
                    .filter { selectedIDs.contains($0.id) }
                    .map(\.pathDescription)
            }
        )
    }

    private func restoreUninstallSelection(matching paths: Set<String>) {
        guard !paths.isEmpty else { return }
        selectedIDs = Set(
            categories.flatMap { item in
                (item.children ?? [])
                    .filter { paths.contains($0.pathDescription) }
                    .map(\.id)
            }
        )
    }

    private func clean(_ items: [CategoryItem], clearingAllSelection: Bool) {
        let cleanedIDs = Set(items.map { $0.id })
        let snapshot = categories
        let cleaner = cleaner
        let cleaningMode = scanMode
        isCleaning = true
        cleaningErrorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = cleaner.clean(items, in: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.categories = result.categories
                self.isCleaning = false
                if result.failures.contains(where: self.requiresFullDiskAccess) {
                    self.needsFullDiskAccess = result.failures.contains(where: self.requiresFullDiskAccess)
                }
                if !result.failures.isEmpty {
                    self.cleaningErrorMessage = self.cleanFailureMessage(result.failures)
                }
                if clearingAllSelection {
                    self.selectedIDs = []
                } else {
                    self.selectedIDs.subtract(cleanedIDs)
                }
                self.scanCache.removeAll()
                self.loadRealDiskSpace()
                if cleaningMode == .uninstallApps, self.scanMode == cleaningMode {
                    self.performScan()
                } else {
                    self.cacheCurrentScan(for: self.scanMode)
                }
            }
        }
    }

    private func cacheCurrentScan(for mode: ScanMode) {
        scanCache[mode] = ScanSnapshot(
            categories: categories,
            needsFullDiskAccess: needsFullDiskAccess
        )
    }

    private func cleanFailureMessage(_ failures: [CleanFailure]) -> String {
        let requiresAccess = failures.contains(where: requiresFullDiskAccess)
        let displayedFailures = failures.prefix(8).map { failure in
            "\(failure.path)\n\(failure.domain) (\(failure.code)): \(failure.reason)"
        }
        var message = displayedFailures.joined(separator: "\n\n")
        if requiresAccess {
            let guidance = String(localized: "macOS blocked access to another app's protected container. Grant LittleClean Full Disk Access, then quit and reopen the app.")
            message = "\(guidance)\n\n\(message)"
        }
        if failures.count > displayedFailures.count {
            message += "\n\n… \(failures.count - displayedFailures.count) more errors"
        }
        return message
    }

    private func requiresFullDiskAccess(_ failure: CleanFailure) -> Bool {
        failure.domain == NSCocoaErrorDomain
            && failure.code == NSFileWriteNoPermissionError
            && isProtectedContainerPath(failure.path)
    }

    private func isProtectedContainerPath(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let libraryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .path
        return expandedPath.hasPrefix("\(libraryPath)/Containers/")
            || expandedPath.hasPrefix("\(libraryPath)/Group Containers/")
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

    private func filterUninstallApplications(
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

    private func collectCleanableSelected(from items: [CategoryItem]) -> [CategoryItem] {
        var result: [CategoryItem] = []
        for item in items {
            if item.isAtomicSelection {
                let selectedChildren = (item.children ?? []).filter {
                    $0.isSelectionDetail && selectedIDs.contains($0.id)
                }
                guard selectedChildren.contains(where: \.isRequiredSelectionDetail) else {
                    continue
                }
                var plannedItem = item
                plannedItem.children = selectedChildren
                plannedItem.sizeBytes = selectedChildren.reduce(Int64(0)) {
                    $0 + $1.sizeBytes
                }
                plannedItem.sizeString = plannedItem.sizeBytes > 0
                    ? formatBytes(plannedItem.sizeBytes)
                    : ""
                plannedItem.rule.cleanType = .trashPaths(
                    selectedChildren.map(\.pathDescription)
                )
                result.append(plannedItem)
            } else if let children = item.children, !children.isEmpty {
                result.append(contentsOf: collectCleanableSelected(from: children))
            } else if item.rule.cleanType != .none && selectedIDs.contains(item.id) {
                result.append(item)
            }
        }
        return result
    }

    private func leafIDs(_ item: CategoryItem) -> Set<UUID> {
        if item.isAtomicSelection {
            return Set(uninstallDetailIDs(item))
        }
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

    private func uninstallDetailIDs(_ item: CategoryItem) -> [UUID] {
        (item.children ?? [])
            .filter(\.isSelectionDetail)
            .map(\.id)
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
