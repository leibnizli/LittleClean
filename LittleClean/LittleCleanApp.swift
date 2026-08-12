//
//  LittleCleanApp.swift
//  LittleClean
//
//  Created by admin on 2026/7/27.
//

import SwiftUI

@main
struct LittleCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .help) {
                Link("Website", destination: URL(string: "https://arayofsunshine.dev/")!)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    /// True when launched for Services / App Intents / similar, not a normal Dock click.
    private(set) var isBackgroundServiceLaunch = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDefaultLaunch = (
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        ) ?? true
        isBackgroundServiceLaunch = !isDefaultLaunch

        NSApp.servicesProvider = FinderUninstallServiceProvider()
        NSUpdateDynamicServices()

        if isBackgroundServiceLaunch {
            // Launched to handle a Finder Service: stay out of the Dock and hide
            // the main window while the uninstall runs.
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                self.suppressMainWindows()
            }
            // Safety net. launchIsDefaultUserInfoKey is a launch-time guess and
            // can be false for launches that are not real service requests. If no
            // service callback arrives within the grace period, recover to a
            // normal windowed app instead of lingering as an invisible accessory
            // that would swallow the next launch from Xcode or the Dock.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !BackgroundUninstallCoordinator.shared.receivedServiceRequest else { return }
                self.recoverToNormalApp()
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Clicking the app in the Dock/Finder while it is hiding as a background
        // service should bring the main window back.
        if isBackgroundServiceLaunch && !BackgroundUninstallCoordinator.shared.isBusy {
            recoverToNormalApp()
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if isBackgroundServiceLaunch || BackgroundUninstallCoordinator.shared.isBusy {
            return false
        }
        return true
    }

    func prepareForBackgroundUninstall() {
        guard isBackgroundServiceLaunch else { return }
        NSApp.setActivationPolicy(.accessory)
        suppressMainWindows()
    }

    func finishBackgroundUninstall() {
        guard isBackgroundServiceLaunch else { return }
        NSApp.terminate(nil)
    }

    private func suppressMainWindows() {
        for window in NSApp.windows where window.isVisible {
            if window === NSApp.modalWindow { continue }
            if window.level >= .modalPanel { continue }
            window.orderOut(nil)
        }
    }

    /// Switches back from the hidden background-service state to a normal,
    /// windowed app so the main window is visible again.
    private func recoverToNormalApp() {
        isBackgroundServiceLaunch = false
        NSApp.setActivationPolicy(.regular)
        for window in NSApp.windows where !window.isVisible {
            if window === NSApp.modalWindow { continue }
            if window.level >= .modalPanel { continue }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
