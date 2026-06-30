import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var shortcutWindow: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusImage()
        rebuildMenu()
        observeState()
    }

    private func observeState() {
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusImage()
                    self?.rebuildMenu()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        if appState.isMuted, appState.isBridgeEnabled {
            symbolName = "mic.slash.fill"
        } else if appState.isBridgeEnabled {
            symbolName = "mic.fill"
        } else {
            symbolName = "mic"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MicBridge")
        image?.isTemplate = true
        button.image = image
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        if !appState.isBridgeEnabled {
            return "MicBridge: 停止中"
        }
        return appState.isMuted ? "MicBridge: ミュート中" : "MicBridge: 稼働中"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let statusLabel = NSMenuItem(
            title: statusLabelString(),
            action: nil,
            keyEquivalent: ""
        )
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(NSMenuItem.separator())

        let bridgeItem = NSMenuItem(
            title: appState.isBridgeEnabled ? "ブリッジを停止" : "ブリッジを開始",
            action: #selector(toggleBridge),
            keyEquivalent: ""
        )
        bridgeItem.target = self
        menu.addItem(bridgeItem)

        let muteItem = NSMenuItem(
            title: appState.isMuted ? "ミュート解除" : "ミュート",
            action: #selector(toggleMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.isEnabled = appState.isBridgeEnabled
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())

        let inputItem = NSMenuItem(title: "入力デバイス", action: nil, keyEquivalent: "")
        inputItem.submenu = deviceSubmenu(
            devices: appState.inputDevices,
            selected: appState.inputDevice,
            action: #selector(selectInput(_:)),
            allowNone: false
        )
        menu.addItem(inputItem)

        let outputItem = NSMenuItem(title: "出力デバイス（仮想マイクへ）", action: nil, keyEquivalent: "")
        outputItem.submenu = deviceSubmenu(
            devices: appState.outputDevices,
            selected: appState.outputDevice,
            action: #selector(selectOutput(_:)),
            allowNone: false
        )
        menu.addItem(outputItem)

        let monitorItem = NSMenuItem(title: "モニター出力", action: nil, keyEquivalent: "")
        monitorItem.submenu = deviceSubmenu(
            devices: appState.outputDevices,
            selected: appState.monitorDevice,
            action: #selector(selectMonitor(_:)),
            allowNone: true
        )
        menu.addItem(monitorItem)

        menu.addItem(NSMenuItem.separator())

        let shortcutItem = NSMenuItem(
            title: "ショートカット設定…",
            action: #selector(openShortcutSettings),
            keyEquivalent: ","
        )
        shortcutItem.target = self
        menu.addItem(shortcutItem)

        let quitItem = NSMenuItem(
            title: "MicBridge を終了",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        if let error = appState.errorMessage {
            menu.addItem(NSMenuItem.separator())
            let errorItem = NSMenuItem(title: "⚠ \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        statusItem.menu = menu
    }

    private func statusLabelString() -> String {
        if !appState.isBridgeEnabled { return "停止中" }
        return appState.isMuted ? "稼働中（ミュート）" : "稼働中"
    }

    private func deviceSubmenu(
        devices: [AudioDevice],
        selected: AudioDevice?,
        action: Selector,
        allowNone: Bool
    ) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if allowNone {
            let none = NSMenuItem(title: "なし", action: action, keyEquivalent: "")
            none.target = self
            none.state = (selected == nil) ? .on : .off
            none.representedObject = nil as AudioDevice?
            submenu.addItem(none)
            submenu.addItem(NSMenuItem.separator())
        }

        if devices.isEmpty {
            let empty = NSMenuItem(title: "(利用可能なデバイスなし)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            return submenu
        }

        for device in devices {
            let item = NSMenuItem(title: device.name, action: action, keyEquivalent: "")
            item.target = self
            item.state = (selected?.uid == device.uid) ? .on : .off
            item.representedObject = device
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func toggleBridge() {
        appState.toggleBridge()
    }

    @objc private func toggleMute() {
        appState.toggleMute()
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        appState.selectInput(sender.representedObject as? AudioDevice)
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        appState.selectOutput(sender.representedObject as? AudioDevice)
    }

    @objc private func selectMonitor(_ sender: NSMenuItem) {
        appState.selectMonitor(sender.representedObject as? AudioDevice)
    }


    @objc private func openShortcutSettings() {
        if let window = shortcutWindow {
            activateAndShow(window)
            return
        }
        let hostingView = NSHostingView(rootView: ShortcutSettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MicBridge ショートカット設定"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MicBridge.ShortcutSettings")
        window.center()
        shortcutWindow = window
        activateAndShow(window)
    }

    private func activateAndShow(_ window: NSWindow) {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
