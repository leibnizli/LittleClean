import Foundation

nonisolated func formatBytes(_ bytes: Int64) -> String {
    if bytes == 0 { return "0 KB" }

    let kb = Double(bytes) / 1000.0
    let mb = kb / 1000.0
    let gb = mb / 1000.0
    let tb = gb / 1000.0

    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 3
    formatter.maximumFractionDigits = 3
    formatter.numberStyle = .decimal

    if tb >= 1.0 {
        return "\(formatter.string(from: NSNumber(value: tb)) ?? "0.000") TB"
    } else if gb >= 1.0 {
        return "\(formatter.string(from: NSNumber(value: gb)) ?? "0.000") GB"
    } else if mb >= 1.0 {
        return "\(formatter.string(from: NSNumber(value: mb)) ?? "0.000") MB"
    } else {
        return "\(formatter.string(from: NSNumber(value: kb)) ?? "0.000") KB"
    }
}
