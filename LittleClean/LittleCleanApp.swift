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
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                self.suppressMainWindows()
            }
        }
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
}
