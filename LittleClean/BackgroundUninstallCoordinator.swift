import AppKit
import Combine
import Foundation
import SwiftUI

/// Runs uninstall from Finder Services / App Intents without presenting the main window.
@MainActor
final class BackgroundUninstallCoordinator {
    static let shared = BackgroundUninstallCoordinator()

    private(set) var isBusy = false
    private let scanner = FileSystemScanner()
    private let cleaner = Cleaner()

    private init() {}

    func handle(appURLs: [URL]) async {
        let appPaths = appURLs
            .map { $0.standardizedFileURL.path }
            .filter { $0.lowercased().hasSuffix(".app") }

        guard !appPaths.isEmpty else {
            presentAlert(
                title: String(localized: "Uninstall with LittleClean"),
                message: String(localized: "The selection is not an application bundle.")
            )
            AppDelegate.shared?.finishBackgroundUninstall()
            return
        }
        guard !isBusy else { return }

        isBusy = true
        AppDelegate.shared?.prepareForBackgroundUninstall()
        defer {
            isBusy = false
            AppDelegate.shared?.finishBackgroundUninstall()
        }

        let result = await Task.detached(priority: .userInitiated) { [scanner] in
            let planned = scanner.makeUninstallPlans(forAppPaths: appPaths)
            let measured = planned.plans.map { plan in
                FileSystemScanner.BackgroundUninstallPlan(
                    item: scanner.measureUninstallApplication(plan.item),
                    accessDenied: plan.accessDenied
                )
            }
            return (plans: measured, skipped: planned.skipped)
        }.value

        guard !result.plans.isEmpty else {
            let message = result.skipped.isEmpty
                ? String(localized: "No removable applications were found.")
                : result.skipped
                    .map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
                    .joined(separator: "\n")
            presentAlert(
                title: String(localized: "Uninstall with LittleClean"),
                message: message
            )
            return
        }

        let panel = BackgroundUninstallConfirmationPanel(
            plans: result.plans,
            skipped: result.skipped
        )
        guard await panel.run() else { return }

        let items = ContentViewModel.collectCleanableSelected(
            from: result.plans.map(\.item),
            selectedIDs: panel.selectedDetailIDs
        )
        guard !items.isEmpty else {
            presentAlert(
                title: String(localized: "Uninstall with LittleClean"),
                message: String(localized: "No removable applications were found.")
            )
            return
        }

        let cleanResult = await Task.detached(priority: .userInitiated) { [cleaner] in
            cleaner.clean(items, in: items)
        }.value

        if !cleanResult.failures.isEmpty {
            let details = cleanResult.failures
                .prefix(8)
                .map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
                .joined(separator: "\n")
            presentAlert(
                title: String(localized: "Deletion Failed"),
                message: details
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Confirmation window

@MainActor
private final class ConfirmationModel: ObservableObject {
    struct Row: Identifiable {
        let id: UUID
        let path: String
        let note: String
        let sizeString: String
        let isRequired: Bool
        var isChecked: Bool
    }

    @Published var rows: [Row]
    let info: String

    init(rows: [Row], info: String) {
        self.rows = rows
        self.info = info
    }
}

@MainActor
private final class BackgroundUninstallConfirmationPanel: NSObject, NSWindowDelegate {
    private let model: ConfirmationModel
    private let window: NSWindow
    private var continuation: CheckedContinuation<Bool, Never>?

    var selectedDetailIDs: Set<UUID> {
        Set(model.rows.filter(\.isChecked).map(\.id))
    }

    init(
        plans: [FileSystemScanner.BackgroundUninstallPlan],
        skipped: [FileSystemScanner.BackgroundUninstallSkip]
    ) {
        let rows = plans.flatMap { plan in
            (plan.item.children ?? []).compactMap { child -> ConfirmationModel.Row? in
                guard child.isSelectionDetail else { return nil }
                return ConfirmationModel.Row(
                    id: child.id,
                    path: child.pathDescription,
                    note: Self.noteText(for: child),
                    sizeString: child.sizeString,
                    isRequired: child.isRequiredSelectionDetail,
                    isChecked: true
                )
            }
        }

        var info = String(
            localized: "The selected application bundle and checked related items will be moved to Trash. Running apps will be quit first."
        )
        if plans.contains(where: \.accessDenied) {
            info += "\n" + String(
                localized: "Some related folders could not be scanned. Grant Full Disk Access for a more complete cleanup."
            )
        }
        let skippedSummary = skipped
            .map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
            .joined(separator: "\n")
        if !skippedSummary.isEmpty {
            info += "\n" + String(localized: "Skipped:") + "\n" + skippedSummary
        }

        model = ConfirmationModel(rows: rows, info: info)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = Self.windowTitle(for: plans)
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: UninstallConfirmationView(
                model: model,
                onCancel: { [weak self] in self?.finish(false) },
                onUninstall: { [weak self] in self?.finish(true) }
            )
        )
        // Assign the autosave name *after* the content view controller. NSHostingController
        // resizes the window to its content's preferred size when assigned, which would
        // clobber any frame the autosave name just restored. Setting it last lets the
        // restore win, so the window reopens at the user's last size and position.
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            if UserDefaults.standard.string(forKey: Self.frameAutosaveDefaultsKey) == nil {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(false)
        return true
    }

    private func finish(_ confirmed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        window.saveFrame(usingName: Self.frameAutosaveName)
        window.orderOut(nil)
        continuation.resume(returning: confirmed)
    }

    private static let frameAutosaveName = "BackgroundUninstallConfirmation"
    private static var frameAutosaveDefaultsKey: String {
        "NSWindow Frame \(frameAutosaveName)"
    }

    private static func windowTitle(
        for plans: [FileSystemScanner.BackgroundUninstallPlan]
    ) -> String {
        let names = plans.map(\.item.name)
        switch names.count {
        case 0:
            return String(localized: "Uninstall Selected Apps?")
        case 1:
            return String(localized: "Uninstall \(names[0])?")
        case 2:
            return String(localized: "Uninstall \(names[0]) and \(names[1])?")
        default:
            let remaining = names.count - 1
            return String(localized: "Uninstall \(names[0]) and \(remaining) more?")
        }
    }

    private static func noteText(for child: CategoryItem) -> String {
        if child.isRequiredSelectionDetail {
            return String(localized: "Application Bundle")
        }
        let path = child.pathDescription
        if path.contains("/Library/Group Containers/") {
            return String(localized: "App Group Container")
        }
        if path.contains("/Library/Containers/") {
            return String(localized: "App Container")
        }
        if path.contains("/Library/Preferences/") {
            return String(localized: "Preferences")
        }
        if path.contains("/Library/Caches/") {
            return String(localized: "Cache")
        }
        if path.contains("/Library/Logs/") {
            return String(localized: "Log")
        }
        if path.contains("/Library/LaunchAgents/")
            || path.contains("/Library/LaunchDaemons/") {
            return String(localized: "Launch Agent")
        }
        if path.contains("/Library/Application Support/")
            || path.contains("/Library/Application Scripts/") {
            return String(localized: "Related App Data")
        }
        if path.contains("/Library/Saved Application State/") {
            return String(localized: "Saved App State")
        }
        return String(localized: "Related App Data")
    }
}

private struct UninstallConfirmationView: View {
    @ObservedObject var model: ConfirmationModel
    let onCancel: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.info)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(model.rows) {
                TableColumn("Path") { row in
                    HStack(spacing: 6) {
                        Button {
                            toggle(row)
                        } label: {
                            Image(
                                systemName: row.isChecked
                                    ? "checkmark.square.fill"
                                    : "square"
                            )
                            .foregroundColor(
                                row.isRequired
                                    ? .secondary
                                    : Color(NSColor.controlAccentColor)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(row.isRequired)
                        .help(
                            row.isRequired
                                ? Text("The application bundle is required.")
                                : Text("Include this related file in the uninstall plan.")
                        )

                        Text(verbatim: row.path)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.path)
                    }
                }

                TableColumn("Note") { row in
                    Text(row.note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 120, max: 280)

                TableColumn("Size") { row in
                    Text(row.sizeString)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70, max: 90)

                TableColumn("") { row in
                    Button {
                        reveal(row.path)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(Text("Reveal in Finder"))
                }
                .width(min: 30, ideal: 30, max: 30)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .selectionDisabled()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive, action: onUninstall)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 360)
    }

    private func toggle(_ row: ConfirmationModel.Row) {
        guard !row.isRequired,
              let index = model.rows.firstIndex(where: { $0.id == row.id }) else {
            return
        }
        model.rows[index].isChecked.toggle()
    }

    private func reveal(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }
}
