import AppKit
import SwiftUI

@main
struct ClipVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mixer = MixerModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(mixer)
        } label: {
            Image(systemName: mixer.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces with LSUIElement: never show a Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MixerModel.shared.shutdown() }
    }
}
