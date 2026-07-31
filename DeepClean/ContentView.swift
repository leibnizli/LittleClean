import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @AppStorage("hasSeenDeepAnalysisIntroduction")
    private var hasSeenDeepAnalysisIntroduction = false
    @State private var isShowingDeepAnalysisIntroduction = false

    var body: some View {
        VStack(spacing: 0) {
            topStatusBar
            Divider()
            cleanListView
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
            viewModel.performScan()
            viewModel.checkForUpdates()
        }
        .alert(
            "Deletion Failed",
            isPresented: Binding(
                get: { viewModel.cleaningErrorMessage != nil },
                set: { if !$0 { viewModel.cleaningErrorMessage = nil } }
            )
        ) {
            if viewModel.needsFullDiskAccess {
                Button("Open Full Disk Access Settings") {
                    viewModel.openFullDiskAccessSettings()
                    viewModel.cleaningErrorMessage = nil
                }
            }
            Button("OK", role: .cancel) {
                viewModel.cleaningErrorMessage = nil
            }
        } message: {
            Text(viewModel.cleaningErrorMessage ?? "")
        }
    }

    // MARK: - Cleanable Directory Outline Table

    private var cleanListView: some View {
        Table(viewModel.displayedCategories, children: \.children, sortOrder: $viewModel.sortOrder) {
            TableColumn("Path", value: \.pathDescription) { item in
                HStack(alignment: .center, spacing: 6) {
                    if let children = item.children, !children.isEmpty {
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
                        let state = viewModel.selectionState(for: item)
                        let enabled = viewModel.isCleanable(item)
                        Button {
                            viewModel.toggleSelection(item)
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
                Text(item.sizeString)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.secondary)
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
        if viewModel.scanMode == .safeCleanup,
           !item.isDisplayOnly,
           !item.rule.isCheckboxHidden,
           item.sizeBytes > 0 {
            Button(LocalizedStringKey("Clean \"\(item.name)\"")) {
                viewModel.cleanSingleItem(item)
            }
        }

        let target = item.isDisplayOnly ? item.finderPath : item.pathDescription
        if let target, !target.isEmpty {
            Button("Reveal in Finder") {
                viewModel.openInFinder(pathDescription: target)
            }
        }
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack(spacing: 14) {
            Label(
                "\(formatBytes(viewModel.usedBytes)) / \(formatBytes(viewModel.totalBytes))",
                systemImage: "internaldrive"
            )
            .foregroundColor(.secondary)
            .font(.system(size: 12))

            Text("Free \(formatBytes(viewModel.freeBytes))")
                .foregroundColor(.green)
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

            if viewModel.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if viewModel.isCleaning {
                ProgressView()
                    .controlSize(.small)
                Text("Cleaning…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if viewModel.isLoadingDetails {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
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
            Text("Safe Cleanup")
                .tag(ScanMode.safeCleanup)
            Text("Deep Analysis")
                .tag(ScanMode.deepAnalysis)
        }
        .pickerStyle(.segmented)
        .disabled(viewModel.isScanning || viewModel.isLoadingDetails || viewModel.isCleaning)
        .help(
            viewModel.scanMode == .safeCleanup
                ? Text("Lower-risk paths that can be cleaned.")
                : Text("Read-only content outside Safe Cleanup.")
        )
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
        SystemSearchField(
            text: $viewModel.searchText,
            placeholder: String(localized: "Search")
        )
        .frame(width: 180)
        .disabled(viewModel.isScanning || viewModel.isLoadingDetails)
    }

    private var scanModeSelection: Binding<ScanMode> {
        Binding(
            get: { viewModel.scanMode },
            set: { newMode in
                if newMode == .deepAnalysis && !hasSeenDeepAnalysisIntroduction {
                    isShowingDeepAnalysisIntroduction = true
                } else {
                    Task { @MainActor in
                        await Task.yield()
                        viewModel.selectScanMode(newMode)
                    }
                }
            }
        )
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 14) {
            if viewModel.scanMode == .safeCleanup {
                Button {
                    viewModel.performCleanSelected()
                } label: {
                    Text("Clean")
                }
                .disabled(viewModel.selectedIDs.isEmpty || viewModel.isScanning || viewModel.isCleaning)
                .buttonStyle(.borderedProminent)
                if !viewModel.selectedIDs.isEmpty {
                    Text("Selected \(formatBytes(viewModel.selectedTotalBytes))")
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

        // The built-in cancel button clears the field without posting a text-change notification.
        @objc func searchFieldDidAct(_ sender: NSSearchField) {
            onChange(sender.stringValue)
        }
    }
}

#Preview {
    ContentView()
}
