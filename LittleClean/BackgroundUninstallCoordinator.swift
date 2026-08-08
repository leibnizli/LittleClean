import AppKit
import Foundation

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
            scanner.makeUninstallPlans(forAppPaths: appPaths)
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
        NSApp.activate(ignoringOtherApps: true)
        // NSAlert returns alertFirstButtonReturn (1000), not .OK (1).
        guard panel.runModal() == .alertFirstButtonReturn else { return }

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

// MARK: - Confirmation panel

@MainActor
private final class BackgroundUninstallConfirmationPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let id: UUID
        let title: String
        let subtitle: String
        let isRequired: Bool
        var isSelected: Bool
    }

    private var rows: [Row]
    private let skippedSummary: String
    private let alert = NSAlert()
    private let tableView = NSTableView()
    private let checkboxColumnID = NSUserInterfaceItemIdentifier("checkbox")
    private let titleColumnID = NSUserInterfaceItemIdentifier("title")

    var selectedDetailIDs: Set<UUID> {
        Set(rows.filter(\.isSelected).map(\.id))
    }

    init(
        plans: [FileSystemScanner.BackgroundUninstallPlan],
        skipped: [FileSystemScanner.BackgroundUninstallSkip]
    ) {
        rows = plans.flatMap { plan in
            (plan.item.children ?? []).compactMap { child -> Row? in
                guard child.isSelectionDetail else { return nil }
                return Row(
                    id: child.id,
                    title: child.pathDescription,
                    subtitle: "\(plan.item.name) · \(child.name)",
                    isRequired: child.isRequiredSelectionDetail,
                    isSelected: true
                )
            }
        }
        skippedSummary = skipped
            .map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
            .joined(separator: "\n")
        super.init()
        configureAlert(accessDenied: plans.contains(where: \.accessDenied))
    }

    func runModal() -> NSApplication.ModalResponse {
        alert.runModal()
    }

    private func configureAlert(accessDenied: Bool) {
        alert.messageText = String(localized: "Uninstall Selected Apps?")
        var info = String(
            localized: "The selected application bundle and checked related items will be moved to Trash. Running apps will be quit first."
        )
        if accessDenied {
            info += "\n\n" + String(
                localized: "Some related folders could not be scanned. Grant Full Disk Access for a more complete cleanup."
            )
        }
        if !skippedSummary.isEmpty {
            info += "\n\n" + String(localized: "Skipped:") + "\n" + skippedSummary
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        tableView.headerView = nil
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .textBackgroundColor
        tableView.rowHeight = 36
        tableView.dataSource = self
        tableView.delegate = self

        let checkboxColumn = NSTableColumn(identifier: checkboxColumnID)
        checkboxColumn.width = 28
        tableView.addTableColumn(checkboxColumn)

        let titleColumn = NSTableColumn(identifier: titleColumnID)
        titleColumn.width = 480
        tableView.addTableColumn(titleColumn)

        scrollView.documentView = tableView
        alert.accessoryView = scrollView
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let item = rows[row]

        if tableColumn.identifier == checkboxColumnID {
            let identifier = NSUserInterfaceItemIdentifier("CheckboxCell")
            let button: NSButton
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton {
                button = reused
            } else {
                button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
                button.identifier = identifier
            }
            button.state = item.isSelected ? .on : .off
            button.isEnabled = !item.isRequired
            button.tag = row
            return button
        }

        let identifier = NSUserInterfaceItemIdentifier("TitleCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = item.title
        cell.textField?.toolTip = item.subtitle
        return cell
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard rows.indices.contains(row), !rows[row].isRequired else {
            sender.state = .on
            return
        }
        rows[row].isSelected = sender.state == .on
    }
}
