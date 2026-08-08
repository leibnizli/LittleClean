import AppIntents
import Foundation

struct UninstallApplicationIntent: AppIntent {
    static var title: LocalizedStringResource = "Uninstall with LittleClean"
    static var description = IntentDescription(
        "Move selected applications and their related leftovers to Trash."
    )
    static var openAppWhenRun = false
    static var isDiscoverable = true

    @Parameter(
        title: "Applications",
        description: "Application bundles to uninstall",
        supportedTypeIdentifiers: ["com.apple.application-bundle"],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var applications: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Uninstall \(\.$applications) with LittleClean")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let urls = applications.compactMap { $0.fileURL?.standardizedFileURL }
        guard !urls.isEmpty else {
            throw $applications.needsValueError(
                IntentDialog(stringLiteral: String(localized: "The selection is not an application bundle."))
            )
        }

        await BackgroundUninstallCoordinator.shared.handle(appURLs: urls)
        return .result()
    }
}

struct LittleCleanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UninstallApplicationIntent(),
            phrases: [
                "Uninstall with \(.applicationName)",
                "Uninstall app with \(.applicationName)"
            ],
            shortTitle: "Uninstall with LittleClean",
            systemImageName: "trash"
        )
    }
}
