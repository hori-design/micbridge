import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menuBarController = MenuBarController(appState: appState)
        appState.registerShortcuts()

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.appState.audioPermissionGranted()
                } else {
                    self.appState.errorMessage = "マイクへのアクセスが許可されていません。システム設定 > プライバシーとセキュリティ > マイク で MicBridge を許可してください。"
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopBridge()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
