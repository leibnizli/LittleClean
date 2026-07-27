import SwiftUI
import Charts

struct CategoryItem: Identifiable {
    let id = UUID()
    let name: String
    let pathDescription: String
    let iconName: String
    let iconColor: Color
    let sizeString: String
    var isSelected: Bool = true
}

struct DiskSpaceItem: Identifiable {
    let id = UUID()
    let category: String
    let value: Double
    let color: Color
}

struct ContentView: View {
    // Disk Space State
    @State private var diskUsage: [DiskSpaceItem] = []
    @State private var totalBytes: Int64 = 0
    @State private var freeBytes: Int64 = 0
    @State private var usedBytes: Int64 = 0
    
    @State private var categories: [CategoryItem] = [
        CategoryItem(name: "App Caches", pathDescription: "~/Library/Caches", iconName: "archivebox.fill", iconColor: .orange, sizeString: "14.2 GB"),
        CategoryItem(name: "System Logs", pathDescription: "~/Library/Logs", iconName: "doc.text.fill", iconColor: .blue, sizeString: "1.8 GB"),
        CategoryItem(name: "System Trash", pathDescription: "~/.Trash", iconName: "trash.fill", iconColor: .red, sizeString: "5.6 GB"),
        CategoryItem(name: "Xcode DerivedData", pathDescription: "~/Library/Developer/Xcode/DerivedData", iconName: "hammer.fill", iconColor: .purple, sizeString: "18.4 GB"),
        CategoryItem(name: "Leftover Files", pathDescription: "~/Library/Application Support, Containers...", iconName: "folder.badge.minus", iconColor: .pink, sizeString: "3.2 GB")
    ]
    
    var usedPercentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(Double(usedBytes) / Double(totalBytes) * 100)
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Column: Disk Usage Overview & Pie Chart
            VStack(alignment: .leading, spacing: 18) {
                
                // Solid Pie Chart
                Chart(diskUsage) { item in
                    SectorMark(
                        angle: .value("Capacity", item.value),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(item.color)
                }
                .frame(height: 190)
                
                HStack {
                    Spacer()
                    VStack(spacing: 2) {
                        Text("\(usedPercentage)%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Disk Space Used")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                VStack(spacing: 12) {
                    HStack {
                        Label("Used Space", systemImage: "circle.fill")
                            .foregroundColor(.blue)
                            .font(.subheadline)
                        Spacer()
                        Text(formatBytes(usedBytes))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    
                    HStack {
                        Label("Available Space", systemImage: "circle.fill")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Spacer()
                        Text(formatBytes(freeBytes))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    
                    Divider()
                        .padding(.vertical, 2)
                    
                    HStack {
                        Text("Total Capacity")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Spacer()
                        Text(formatBytes(totalBytes))
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(12)
                
                Button(action: {
                    // Scan logic placeholder
                }) {
                    Text("Scan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Spacer()
            }
            .padding(24)
            .frame(width: 290)
            .background(Color(NSColor.windowBackgroundColor))
            .onAppear {
                loadRealDiskSpace()
            }
            
            Divider()
            
            // MARK: - Right Column: Cleanable Directory List
            VStack(alignment: .leading, spacing: 0) {
                List {
                    ForEach(categories) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 14, weight: .medium))
                                Text(item.pathDescription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(item.sizeString)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                                .padding(.trailing, 8)
                            
                            Button {
                                openInFinder(pathDescription: item.pathDescription)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            
                            Button("Clean") {
                                // Clean logic placeholder
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            .background(Color(NSColor.underPageBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 520)
    }
    
    // Load real macOS system disk capacity
    private func loadRealDiskSpace() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            if let total = values.volumeTotalCapacity,
               let free = values.volumeAvailableCapacityForImportantUsage {
                let totalVal = Int64(total)
                let freeVal = Int64(free)
                let usedVal = max(0, totalVal - freeVal)
                
                self.totalBytes = totalVal
                self.freeBytes = freeVal
                self.usedBytes = usedVal
                
                let usedGB = Double(usedVal) / 1_000_000_000.0
                let freeGB = Double(freeVal) / 1_000_000_000.0
                
                self.diskUsage = [
                    DiskSpaceItem(category: "Used Space", value: usedGB, color: .blue),
                    DiskSpaceItem(category: "Available Space", value: freeGB, color: Color.gray.opacity(0.3))
                ]
            }
        } catch {
            print("Failed to load real disk space: \(error)")
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // Open directory in Finder
    private func openInFinder(pathDescription: String) {
        let expandedPath = NSString(string: pathDescription).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ContentView()
}



