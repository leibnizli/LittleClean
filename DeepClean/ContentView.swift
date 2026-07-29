import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()

    var body: some View {
        VStack(spacing: 0) {
            topStatusBar
            Divider()
            cleanListView
            Divider()
            bottomActionBar
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            viewModel.performScan()
            viewModel.checkForUpdates()
        }
        .searchable(text: $viewModel.searchText, prompt: "Search")
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
            .width(min: 80, ideal: 110, max: 150)

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
        if !item.isDisplayOnly && !item.rule.isCheckboxHidden && item.sizeBytes > 0 {
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
                .buttonStyle(.bordered)
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
            } else {
                if viewModel.isLoadingDetails {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning Home…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 14) {
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

#Preview {
    ContentView()
}
