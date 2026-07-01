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
        // ブリッジを止めるだけ。userWantsBridgeRunning は保持して次回起動時に自動再開させる。
        appState.bridge.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
