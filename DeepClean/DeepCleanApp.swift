//
//  DeepCleanApp.swift
//  DeepClean
//
//  Created by admin on 2026/7/27.
//

import SwiftUI

@main
struct DeepCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .help) {
                Link("Website", destination: URL(string: "https://arayofsunshine.dev/")!)
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
