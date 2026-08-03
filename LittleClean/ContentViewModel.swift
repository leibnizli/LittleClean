import AppKit
import Combine
import SwiftUI

@MainActor
final class ContentViewModel: ObservableObject {
    @Published var totalBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    @Published var usedBytes: Int64 = 0
    @Published var newVersionURL: String?
    @Published var cleaningErrorMessage: String?
    @Published var cleaningErrorNeedsFullDiskAccess = false
    @Published var needsFullDiskAccess = false
    @Published var scanMode: ScanMode = .uninstallApps

    let uninstallSession = ScanModeSession(mode: .uninstallApps)
    let safeCleanupSession = ScanModeSession(mode: .safeCleanup)
    let deepAnalysisSession = ScanModeSession(mode: .deepAnalysis)

    private let scanner: FileSystemScanner
    private let cleaner: Cleaner
    private let updateChecker: UpdateChecker
    private var cancellables = Set<AnyCancellable>()

    init(
        scanner: FileSystemScanner = FileSystemScanner(),
        cleaner: Cleaner = Cleaner(),
        updateChecker: UpdateChecker = UpdateChecker()
    ) {
        self.scanner = scanner
        self.cleaner = cleaner
        self.updateChecker = updateChecker

        for session in [uninstallSession, safeCleanupSession, deepAnalysisSession] {
            session.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    var activeSession: ScanModeSession {
        session(for: scanMode)
    }

    var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(Double(usedBytes) / Double(totalBytes) * 100)
    }

    func session(for mode: ScanMode) -> ScanModeSession {
        switch mode {
        case .uninstallApps: return uninstallSession
        case .safeCleanup: return safeCleanupSession
        case .deepAnalysis: return deepAnalysisSession
        }
    }

    func selectScanMode(_ mode: ScanMode) {
        guard mode != scanMode else { return }
        scanMode = mode
        ensureLoaded(mode)
    }

    func ensureLoaded(_ mode: ScanMode? = nil) {
        let target = mode ?? scanMode
        let session = session(for: target)
        guard !session.hasLoaded, !session.isScanning else { return }
        performScan(for: target)
    }

    func refreshFullDiskAccessStatus() {
        let scanner = scanner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let granted = scanner.hasFullDiskAccess()
            DispatchQueue.main.async {
                self?.needsFullDiskAccess = !granted
            }
        }
    }

    func performScan(for mode: ScanMode? = nil) {
        let targetMode = mode ?? scanMode
        let session = session(for: targetMode)
        session.scanToken += 1
        let token = session.scanToken
        session.detailsLoadToken += 1
        session.isScanning = true
        session.isLoadingDetails = false
        session.categories = []
        session.selectedIDs = []
        session.hasLoaded = false
        loadRealDiskSpace()

        let scanner = scanner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.scanCategories(mode: targetMode)
            DispatchQueue.main.async {
                guard let self else { return }
                let session = self.session(for: targetMode)
                guard token == session.scanToken else { return }
                session.categories = result.categories
                session.isScanning = false
                session.hasLoaded = true
                if targetMode == .deepAnalysis {
                    self.loadDetails(session: session, scanToken: token)
                } else if targetMode == .uninstallApps {
                    self.loadUninstallEnrichment(session: session, scanToken: token)
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

    func performCleanSelected(in session: ScanModeSession? = nil) {
        let session = session ?? activeSession
        guard session.mode.allowsCleaning else { return }
        let items = Self.collectCleanableSelected(
            from: session.categories,
            selectedIDs: session.selectedIDs
        )
        guard !items.isEmpty else { return }
        clean(items, in: session, clearingAllSelection: true)
    }

    func cleanSingleItem(_ item: CategoryItem, in session: ScanModeSession? = nil) {
        let session = session ?? activeSession
        guard session.mode.allowsCleaning else { return }
        if item.isAtomicSelection {
            clean([item], in: session, clearingAllSelection: false)
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
        clean(items, in: session, clearingAllSelection: false)
    }

    func isCleanable(_ item: CategoryItem, in session: ScanModeSession) -> Bool {
        guard session.mode.allowsCleaning else { return false }
        if item.isSelectionDetail { return true }
        if item.rule.cleanType != .none { return true }
        if let children = item.children {
            return children.contains { isCleanable($0, in: session) }
        }
        return false
    }

    func selectionState(for item: CategoryItem, in session: ScanModeSession) -> SelectionState {
        if item.isAtomicSelection {
            let details = Self.uninstallDetailIDs(item)
            guard !details.isEmpty else { return .unchecked }
            let selectedCount = details.filter { session.selectedIDs.contains($0) }.count
            if selectedCount == 0 { return .unchecked }
            if selectedCount == details.count { return .checked }
            return .mixed
        }
        if let children = item.children, !children.isEmpty {
            let leaves = leafIDs(item)
            guard !leaves.isEmpty else { return .unchecked }
            let selected = leaves.intersection(session.selectedIDs).count
            if selected == 0 { return .unchecked }
            if selected == leaves.count { return .checked }
            return .mixed
        }
        return session.selectedIDs.contains(item.id) ? .checked : .unchecked
    }

    func toggleSelection(_ item: CategoryItem, in session: ScanModeSession) {
        if item.isAtomicSelection {
            let details = Set(Self.uninstallDetailIDs(item))
            guard !details.isEmpty else { return }
            if details.isSubset(of: session.selectedIDs) {
                session.selectedIDs.subtract(details)
            } else {
                session.selectedIDs.formUnion(details)
            }
            return
        }
        if item.isSelectionDetail {
            guard !item.isRequiredSelectionDetail else { return }
            if session.selectedIDs.contains(item.id) {
                session.selectedIDs.remove(item.id)
            } else {
                session.selectedIDs.insert(item.id)
                if let parent = session.categories.first(where: {
                    ($0.children ?? []).contains { $0.id == item.id }
                }),
                   let requiredID = parent.children?.first(where: {
                       $0.isRequiredSelectionDetail
                   })?.id {
                    session.selectedIDs.insert(requiredID)
                }
            }
            return
        }
        if let children = item.children, !children.isEmpty {
            let leaves = leafIDs(item)
            if leaves.isSubset(of: session.selectedIDs) {
                session.selectedIDs.subtract(leaves)
            } else {
                session.selectedIDs.formUnion(leaves)
            }
        } else {
            guard item.rule.cleanType != .none else { return }
            if session.selectedIDs.contains(item.id) {
                session.selectedIDs.remove(item.id)
            } else {
                session.selectedIDs.insert(item.id)
            }
        }
    }

    func openInFinder(pathDescription: String) {
        let expandedPath = NSString(string: pathDescription).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func collectCleanableSelected(
        from items: [CategoryItem],
        selectedIDs: Set<UUID>
    ) -> [CategoryItem] {
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
                result.append(contentsOf: collectCleanableSelected(
                    from: children,
                    selectedIDs: selectedIDs
                ))
            } else if item.rule.cleanType != .none && selectedIDs.contains(item.id) {
                result.append(item)
            }
        }
        return result
    }

    static func uninstallDetailIDs(_ item: CategoryItem) -> [UUID] {
        (item.children ?? [])
            .filter(\.isSelectionDetail)
            .map(\.id)
    }

    private func loadDetails(session: ScanModeSession, scanToken: Int) {
        session.detailsLoadToken += 1
        let token = session.detailsLoadToken
        session.isLoadingDetails = true
        let scanner = scanner
        let pendingItems = session.categories.filter { FileSystemScanner.containsPendingSizes($0) }
        let group = DispatchGroup()

        for item in pendingItems {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let measured = scanner.measurePendingSizes(item)
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self else { return }
                    guard token == session.detailsLoadToken,
                          scanToken == session.scanToken,
                          !session.isScanning else { return }
                    if let index = session.categories.firstIndex(where: {
                        $0.name == measured.name
                            && $0.pathDescription == measured.pathDescription
                    }) {
                        session.categories[index] = measured
                        self.objectWillChange.send()
                    }
                }
            }
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            scanner.scanDetailsIncremental { update in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard token == session.detailsLoadToken,
                          scanToken == session.scanToken,
                          !session.isScanning else { return }
                    self.applyDetailUpdate(update, to: session)
                }
            }
            DispatchQueue.main.async {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard token == session.detailsLoadToken,
                  scanToken == session.scanToken,
                  !session.isScanning else { return }
            session.isLoadingDetails = false
            self.objectWillChange.send()
        }
    }

    private func applyDetailUpdate(
        _ update: FileSystemScanner.DetailSectionUpdate,
        to session: ScanModeSession
    ) {
        let sectionName: String
        let sectionIcon: String
        let sectionColor: Color
        let sectionNote: LocalizedStringKey
        switch update.section {
        case .installedTools:
            sectionName = "Installed Tools"
            sectionIcon = "terminal.fill"
            sectionColor = .primary
            sectionNote = "Read Only"
        case .homeDirectory:
            sectionName = "Home Directory"
            sectionIcon = "folder.fill"
            sectionColor = .blue
            sectionNote = "Non-system Items"
        }

        if let index = session.categories.firstIndex(where: {
            $0.name == sectionName && $0.isDisplayOnly
        }) {
            var parent = session.categories[index]
            var children = parent.children ?? []
            if let childIndex = children.firstIndex(where: { $0.name == update.child.name }) {
                children[childIndex] = update.child
            } else {
                children.append(update.child)
            }
            children.sort { $0.sizeBytes > $1.sizeBytes }
            let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
            parent.children = children
            parent.sizeBytes = total
            parent.sizeString = total > 0 ? formatBytes(total) : ""
            session.categories[index] = parent
        } else {
            session.categories.append(
                CategoryItem(
                    name: sectionName,
                    pathDescription: sectionName,
                    iconName: sectionIcon,
                    iconColor: sectionColor,
                    sizeBytes: update.child.sizeBytes,
                    sizeString: update.child.sizeBytes > 0
                        ? formatBytes(update.child.sizeBytes)
                        : "",
                    rule: CleanRule(
                        name: sectionName,
                        pathDescription: sectionName,
                        iconName: sectionIcon,
                        iconColor: sectionColor,
                        cleanType: .none,
                        note: sectionNote,
                        isCheckboxHidden: true,
                        scanMode: .deepAnalysis
                    ),
                    children: [update.child],
                    isDisplayOnly: true
                )
            )
        }
        objectWillChange.send()
    }

    private func loadUninstallEnrichment(session: ScanModeSession, scanToken: Int) {
        session.detailsLoadToken += 1
        let token = session.detailsLoadToken
        let snapshot = session.categories
        let scanner = scanner
        session.isLoadingDetails = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enrichment = scanner.enrichUninstallApplications(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == session.detailsLoadToken,
                      scanToken == session.scanToken,
                      !session.isScanning else { return }
                let selectedPaths = self.selectedUninstallDetailPaths(in: session)
                session.categories = enrichment.items
                self.restoreUninstallSelection(matching: selectedPaths, in: session)
            }

            for item in enrichment.items {
                let measured = scanner.measureUninstallApplication(item)
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard token == session.detailsLoadToken,
                          scanToken == session.scanToken,
                          !session.isScanning else { return }
                    let selectedPaths = self.selectedUninstallDetailPaths(in: session)
                    if let index = session.categories.firstIndex(where: {
                        $0.pathDescription == measured.pathDescription
                    }) {
                        session.categories[index] = measured
                        self.restoreUninstallSelection(matching: selectedPaths, in: session)
                    }
                }
            }

            DispatchQueue.main.async {
                guard token == session.detailsLoadToken,
                      scanToken == session.scanToken,
                      !session.isScanning else { return }
                session.isLoadingDetails = false
            }
        }
    }

    private func selectedUninstallDetailPaths(in session: ScanModeSession) -> Set<String> {
        Set(
            session.categories.flatMap { item in
                (item.children ?? [])
                    .filter { session.selectedIDs.contains($0.id) }
                    .map(\.pathDescription)
            }
        )
    }

    private func restoreUninstallSelection(matching paths: Set<String>, in session: ScanModeSession) {
        guard !paths.isEmpty else { return }
        session.selectedIDs = Set(
            session.categories.flatMap { item in
                (item.children ?? [])
                    .filter { paths.contains($0.pathDescription) }
                    .map(\.id)
            }
        )
    }

    private func clean(
        _ items: [CategoryItem],
        in session: ScanModeSession,
        clearingAllSelection: Bool
    ) {
        let cleanedIDs = Set(items.map { $0.id })
        let snapshot = session.categories
        let cleaner = cleaner
        let cleaningMode = session.mode
        session.isCleaning = true
        cleaningErrorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = cleaner.clean(items, in: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                session.categories = result.categories
                session.isCleaning = false
                let needsAccess = result.failures.contains(where: self.requiresFullDiskAccess)
                self.cleaningErrorNeedsFullDiskAccess = needsAccess
                if !result.failures.isEmpty {
                    self.cleaningErrorMessage = self.cleanFailureMessage(result.failures)
                }
                self.refreshFullDiskAccessStatus()
                if clearingAllSelection {
                    session.selectedIDs = []
                } else {
                    session.selectedIDs.subtract(cleanedIDs)
                }
                self.loadRealDiskSpace()
                if cleaningMode == .uninstallApps {
                    session.categories = self.prunedUninstallCategories(
                        session.categories,
                        cleanedIDs: cleanedIDs
                    )
                } else if cleaningMode == .safeCleanup {
                    session.categories = self.prunedEmptyCleanedCategories(
                        session.categories,
                        cleanedIDs: cleanedIDs
                    )
                }
            }
        }
    }

    private func prunedUninstallCategories(
        _ items: [CategoryItem],
        cleanedIDs: Set<UUID>
    ) -> [CategoryItem] {
        items.filter { item in
            guard item.isAtomicSelection, cleanedIDs.contains(item.id) else {
                return true
            }
            let expanded = NSString(string: item.pathDescription).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded)
        }
    }

    /// Drops cleaned leaves that are now empty, and parents left without children.
    private func prunedEmptyCleanedCategories(
        _ items: [CategoryItem],
        cleanedIDs: Set<UUID>
    ) -> [CategoryItem] {
        items.compactMap { item -> CategoryItem? in
            if let children = item.children, !children.isEmpty {
                let newChildren = prunedEmptyCleanedCategories(children, cleanedIDs: cleanedIDs)
                guard !newChildren.isEmpty else { return nil }
                var rebuilt = item
                rebuilt.children = newChildren
                let total = newChildren.reduce(Int64(0)) { $0 + $1.sizeBytes }
                rebuilt.sizeBytes = total
                rebuilt.sizeString = total > 0 ? formatBytes(total) : ""
                return rebuilt
            }
            if cleanedIDs.contains(item.id), item.sizeBytes <= 0 {
                return nil
            }
            return item
        }
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

    private func leafIDs(_ item: CategoryItem) -> Set<UUID> {
        if item.isAtomicSelection {
            return Set(Self.uninstallDetailIDs(item))
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
