import AppKit
import Foundation

/// Finder Services entry that uninstalls selected .app bundles in the background.
final class FinderUninstallServiceProvider: NSObject {
    @objc func uninstallApplications(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = Self.fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = String(localized: "The selection is not an application bundle.") as NSString
            return
        }

        Task { @MainActor in
            await BackgroundUninstallCoordinator.shared.handle(appURLs: urls)
        }
    }

    private static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        if let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map(\.standardizedFileURL)
        }

        if let paths = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }

        return []
    }
}
