import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @AppStorage("hasSeenDeepAnalysisIntroduction")
    private var hasSeenDeepAnalysisIntroduction = false
    @State private var isShowingDeepAnalysisIntroduction = false
    @State private var isShowingUninstallConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            topStatusBar
            Divider()
            modeTabs
            Divider()
            bottomActionBar
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .principal) {
                scanModePicker
            }
            ToolbarItem(placement: .primaryAction) {
                searchField
            }
        }
        .onAppear {
            if AppDelegate.shared?.isBackgroundServiceLaunch == true {
                NSApp.keyWindow?.orderOut(nil)
                return
            }
            viewModel.ensureLoaded(.uninstallApps)
            viewModel.refreshFullDiskAccessStatus()
            viewModel.checkForUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.refreshFullDiskAccessStatus()
            }
        }
        .alert(
            "Deletion Failed",
            isPresented: Binding(
                get: { viewModel.cleaningErrorMessage != nil },
                set: {
                    if !$0 {
                        viewModel.cleaningErrorMessage = nil
                        viewModel.cleaningErrorNeedsFullDiskAccess = false
                    }
                }
            )
        ) {
            if viewModel.cleaningErrorNeedsFullDiskAccess {
                Button("Open Full Disk Access Settings") {
                    viewModel.openFullDiskAccessSettings()
                    viewModel.cleaningErrorMessage = nil
                    viewModel.cleaningErrorNeedsFullDiskAccess = false
                }
            }
            Button("OK", role: .cancel) {
                viewModel.cleaningErrorMessage = nil
                viewModel.cleaningErrorNeedsFullDiskAccess = false
            }
        } message: {
            Text(viewModel.cleaningErrorMessage ?? "")
        }
    }

    // MARK: - Mode Tabs

    private var modeTabs: some View {
        ZStack {
            ModeListPane(
                viewModel: viewModel,
                session: viewModel.uninstallSession
            )
            .opacity(viewModel.scanMode == .uninstallApps ? 1 : 0)
            .allowsHitTesting(viewModel.scanMode == .uninstallApps)

            ModeListPane(
                viewModel: viewModel,
                session: viewModel.safeCleanupSession
            )
            .opacity(viewModel.scanMode == .safeCleanup ? 1 : 0)
            .allowsHitTesting(viewModel.scanMode == .safeCleanup)

            ModeListPane(
                viewModel: viewModel,
                session: viewModel.deepAnalysisSession
            )
            .opacity(viewModel.scanMode == .deepAnalysis ? 1 : 0)
            .allowsHitTesting(viewModel.scanMode == .deepAnalysis)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        let session = viewModel.activeSession
        return HStack(spacing: 14) {
            HStack(spacing: 6) {
                DiskUsagePieChart(
                    usedBytes: viewModel.usedBytes,
                    freeBytes: viewModel.freeBytes
                )
                .frame(width: 14, height: 14)
                .help("Used \(formatBytes(viewModel.usedBytes)) · Free \(formatBytes(viewModel.freeBytes))")

                Text("\(formatBytes(viewModel.usedBytes)) / \(formatBytes(viewModel.totalBytes))")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }

            Text("Free \(formatBytes(viewModel.freeBytes))")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            if viewModel.needsFullDiskAccess {
                Button {
                    viewModel.openFullDiskAccessSettings()
                } label: {
                    Label("Enable Full Disk Access", systemImage: "lock.shield.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .help("Open Full Disk Access Settings")
            }

            Spacer()

            if session.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if session.isCleaning {
                ProgressView()
                    .controlSize(.small)
                Text("Cleaning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if session.isLoadingDetails {
                ProgressView()
                    .controlSize(.small)
                Text(
                    session.mode == .uninstallApps
                        ? "Analyzing apps…"
                        : "Scanning…"
                )
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button {
                    viewModel.performScan()
                } label: {
                    Text("Scan")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var scanModePicker: some View {
        Picker("Mode", selection: scanModeSelection) {
            Text("Uninstall Apps")
                .tag(ScanMode.uninstallApps)
            Text("Safe Cleanup")
                .tag(ScanMode.safeCleanup)
            Text("Deep Analysis")
                .tag(ScanMode.deepAnalysis)
        }
        .pickerStyle(.segmented)
        .help(scanModeHelp)
        .alert(
            "About Deep Analysis",
            isPresented: $isShowingDeepAnalysisIntroduction
        ) {
            Button("Continue") {
                hasSeenDeepAnalysisIntroduction = true
                viewModel.selectScanMode(.deepAnalysis)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Deep Analysis is read-only and shows content outside Safe Cleanup. Nothing in this mode can be deleted."
            )
        }
    }

    private var searchField: some View {
        let session = viewModel.activeSession
        return SystemSearchField(
            text: Binding(
                get: { session.searchText },
                set: { session.searchText = $0 }
            ),
            placeholder: String(localized: "Search")
        )
        .frame(width: 180)
        .disabled(session.isScanning || session.isLoadingDetails)
        .id(session.mode)
    }

    private var scanModeSelection: Binding<ScanMode> {
        Binding(
            get: { viewModel.scanMode },
            set: { newMode in
                if newMode == .deepAnalysis && !hasSeenDeepAnalysisIntroduction {
                    isShowingDeepAnalysisIntroduction = true
                } else {
                    viewModel.selectScanMode(newMode)
                }
            }
        )
    }

    private var scanModeHelp: Text {
        switch viewModel.scanMode {
        case .uninstallApps:
            Text("Remove installed apps and their matching user data.")
        case .safeCleanup:
            Text("Lower-risk paths that can be cleaned.")
        case .deepAnalysis:
            Text("Read-only content outside Safe Cleanup.")
        }
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        let session = viewModel.activeSession
        return HStack(spacing: 14) {
            if session.mode == .uninstallApps {
                Button {
                    isShowingUninstallConfirmation = true
                } label: {
                    Text("Uninstall")
                }
                .disabled(session.selectedIDs.isEmpty || session.isBusy)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .alert(
                    "Uninstall Selected Apps?",
                    isPresented: $isShowingUninstallConfirmation
                ) {
                    Button("Uninstall", role: .destructive) {
                        viewModel.performCleanSelected(in: session)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(verbatim: uninstallConfirmationMessage(for: session))
                }

                if !session.selectedIDs.isEmpty {
                    Text("Selected \(formatBytes(session.selectedTotalBytes))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else if session.mode == .safeCleanup {
                Button {
                    viewModel.performCleanSelected(in: session)
                } label: {
                    Text("Clean")
                }
                .disabled(session.selectedIDs.isEmpty || session.isScanning || session.isCleaning)
                .buttonStyle(.borderedProminent)
                if !session.selectedIDs.isEmpty {
                    Text("Selected \(formatBytes(session.selectedTotalBytes))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Text("App cannot accurately determine deletable items. Please review carefully.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text("Read-only analysis")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let versionURL = viewModel.newVersionURL, let url = URL(string: versionURL) {
                Link("New Version Available", destination: url)
                    .foregroundColor(.blue)
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func uninstallConfirmationMessage(for session: ScanModeSession) -> String {
        let names = session.selectedItemNames
        let displayedNames = names.prefix(6).joined(separator: "\n")
        let remainingCount = max(0, names.count - 6)
        let remaining = remainingCount > 0
            ? "\n" + String(localized: "…and \(remainingCount) more")
            : ""
        let heading = String(
            localized: "The following apps and their matching files will be moved to Trash:"
        )
        let guidance = String(
            localized: "Quit these apps first. Some containers may require Full Disk Access. Items remain recoverable until Trash is emptied."
        )
        return """
        \(heading)

        \(displayedNames)\(remaining)

        \(guidance)
        """
    }
}

// MARK: - Per-mode list pane (kept alive across tab switches)

@MainActor
private struct ModeListPane: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var session: ScanModeSession

    var body: some View {
        Table(session.displayedCategories, children: \.children, sortOrder: $session.sortOrder) {
            TableColumn("Path", value: \.pathDescription) { item in
                HStack(alignment: .center, spacing: 6) {
                    if item.isAtomicSelection {
                        let state = viewModel.selectionState(for: item, in: session)
                        let enabled = viewModel.isCleanable(item, in: session) && !session.isBusy
                        Button {
                            viewModel.toggleSelection(item, in: session)
                        } label: {
                            Image(systemName: state.symbolName)
                                .foregroundColor(
                                    enabled ? Color(NSColor.controlAccentColor) : .secondary
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)

                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.pathDescription))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    } else if item.isSelectionDetail {
                        let state = viewModel.selectionState(for: item, in: session)
                        let enabled = !item.isRequiredSelectionDetail && !session.isBusy
                        Button {
                            viewModel.toggleSelection(item, in: session)
                        } label: {
                            Image(systemName: state.symbolName)
                                .foregroundColor(
                                    enabled ? Color(NSColor.controlAccentColor) : .secondary
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .help(
                            item.isRequiredSelectionDetail
                                ? Text("The application bundle is required.")
                                : Text("Include this related file in the uninstall plan.")
                        )

                        Image(systemName: item.iconName)
                            .foregroundColor(item.iconColor)
                            .frame(width: 16)
                    } else if let children = item.children, !children.isEmpty {
                        let hasToolIcon = NSImage(
                            systemSymbolName: item.iconName,
                            accessibilityDescription: nil
                        ) != nil
                        Image(systemName: hasToolIcon ? item.iconName : "folder.fill")
                            .foregroundColor(hasToolIcon ? item.iconColor : .blue)
                            .frame(width: 16)
                    } else if item.isDisplayOnly || item.rule.isCheckboxHidden {
                        Image(systemName: item.iconName)
                            .foregroundColor(item.iconColor)
                            .frame(width: 16)
                    } else {
                        let state = viewModel.selectionState(for: item, in: session)
                        let enabled = viewModel.isCleanable(item, in: session) && !session.isBusy
                        Button {
                            viewModel.toggleSelection(item, in: session)
                        } label: {
                            Image(systemName: state.symbolName)
                                .foregroundColor(enabled ? Color(NSColor.controlAccentColor) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                    }

                    Text(verbatim: item.displayPath ?? item.pathDescription)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { itemContextMenu(item) }
            }

            TableColumn("Note") { item in
                Text(item.description ?? item.rule.note ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu { itemContextMenu(item) }
            }
            .width(min: 100, ideal: 180, max: 320)

            TableColumn("Size", value: \.sizeBytes) { item in
                Group {
                    if item.sizeString.isEmpty,
                       session.isLoadingDetails || session.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(item.sizeString)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu { itemContextMenu(item) }
            }
            .width(min: 90, ideal: 110, max: 150)

            TableColumn("") { item in
                let target = item.isDisplayOnly ? item.finderPath : item.pathDescription
                if let target, !target.isEmpty {
                    Button {
                        viewModel.openInFinder(pathDescription: target)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .contextMenu { itemContextMenu(item) }
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .contextMenu { itemContextMenu(item) }
                }
            }
            .width(min: 40, ideal: 50, max: 60)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    @ViewBuilder
    private func itemContextMenu(_ item: CategoryItem) -> some View {
        if session.mode == .safeCleanup,
           !item.isDisplayOnly,
           !item.rule.isCheckboxHidden,
           item.sizeBytes > 0 {
            Button(LocalizedStringKey("Clean \"\(item.name)\"")) {
                viewModel.cleanSingleItem(item, in: session)
            }
        }

        let target = item.isDisplayOnly ? item.finderPath : item.pathDescription
        if let target, !target.isEmpty {
            Button("Reveal in Finder") {
                viewModel.openInFinder(pathDescription: target)
            }
        }
    }
}

private struct DiskUsagePieChart: View {
    let usedBytes: Int64
    let freeBytes: Int64

    private var usedFraction: Double {
        let total = usedBytes + freeBytes
        guard total > 0 else { return 0 }
        return Double(usedBytes) / Double(total)
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let startAngle = Angle.degrees(-90)

            var freePath = Path()
            freePath.addEllipse(in: rect)
            context.fill(freePath, with: .color(Color.secondary.opacity(0.2)))

            if usedFraction > 0 {
                let endAngle = startAngle + .degrees(360 * min(usedFraction, 1))
                var usedPath = Path()
                usedPath.move(to: center)
                usedPath.addArc(
                    center: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )
                usedPath.closeSubpath()
                context.fill(usedPath, with: .color(Color.accentColor))
            }
        }
        .accessibilityLabel("Disk usage")
        .accessibilityValue("\(Int((usedFraction * 100).rounded())) percent used")
    }
}

private struct SystemSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldDidAct(_:))
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.controlSize = .regular
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.onChange = { text = $0 }
        nsView.placeholderString = placeholder
        nsView.isEnabled = context.environment.isEnabled
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var onChange: (String) -> Void = { _ in }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            onChange(field.stringValue)
        }

        @objc func searchFieldDidAct(_ sender: NSSearchField) {
            onChange(sender.stringValue)
        }
    }
}

#Preview {
    ContentView()
}
