import AppKit
import Combine
import CoreAudio
import Foundation
import KeyboardShortcuts
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var inputDevice: AudioDevice?
    @Published private(set) var outputDevice: AudioDevice?
    @Published private(set) var monitorDevice: AudioDevice?
    @Published private(set) var isBridgeEnabled = false
    @Published var isMuted = false
    @Published var isMonitorEnabled = true
    @Published private(set) var isLaunchAtLoginEnabled = false
    @Published var errorMessage: String?
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var inputLevel: Float = 0

    private var preferredInputUID: String?
    private var preferredOutputUID: String?
    private var preferredMonitorUID: String?
    private var userWantsBridgeRunning = false
    private var isAudioAllowed = false

    let deviceManager = AudioDeviceManager()
    let bridge = AudioBridge()

    private let defaults = UserDefaults.standard
    private var deviceChangeObserver: NSObjectProtocol?

    private enum Keys {
        static let inputUID = "inputDeviceUID"
        static let outputUID = "outputDeviceUID"
        static let monitorUID = "monitorDeviceUID"
        static let wasEnabled = "wasBridgeEnabled"
        static let monitorEnabled = "isMonitorEnabled"
    }

    init() {
        preferredInputUID = defaults.string(forKey: Keys.inputUID)
        preferredOutputUID = defaults.string(forKey: Keys.outputUID)
        preferredMonitorUID = defaults.string(forKey: Keys.monitorUID)
        userWantsBridgeRunning = defaults.bool(forKey: Keys.wasEnabled)
        if defaults.object(forKey: Keys.monitorEnabled) != nil {
            isMonitorEnabled = defaults.bool(forKey: Keys.monitorEnabled)
        }
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        devices = deviceManager.allDevices()
        applyActiveDevicesFromPreferred()

        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceListChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDeviceListChanged() }
        }
        deviceManager.startObservingDeviceChanges()
        bridge.onLevelUpdate = { [weak self] level in
            guard let self else { return }
            self.inputLevel = self.isMuted ? 0 : level
        }
    }

    deinit {
        if let obs = deviceChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }
    var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }

    func audioPermissionGranted() {
        isAudioAllowed = true
        reconcile()
    }

    func toggleBridge() {
        if userWantsBridgeRunning { stopBridge() } else { startBridge() }
    }

    func startBridge() {
        userWantsBridgeRunning = true
        persist()
        reconcile()
        if !isBridgeEnabled, errorMessage == nil {
            if inputDevice == nil || outputDevice == nil {
                errorMessage = "入力デバイスと出力デバイスを選択してください"
            }
        }
    }

    func stopBridge() {
        userWantsBridgeRunning = false
        persist()
        teardownBridge()
    }

    func toggleMute() {
        isMuted.toggle()
        applyAudibility()
        if isMuted { inputLevel = 0 }
    }

    func toggleMonitor() {
        isMonitorEnabled.toggle()
        persist()
        applyAudibility()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = nil
        } catch {
            errorMessage = "起動時登録の変更に失敗: \(error.localizedDescription)"
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    /// isMuted / isMonitorEnabled を bridge に反映する。
    /// - output: isMuted のみ
    /// - monitor: isMuted または monitor 無効化どちらかで silence
    private func applyAudibility() {
        bridge.setOutputMuted(isMuted)
        bridge.setMonitorMuted(isMuted || !isMonitorEnabled)
    }

    func selectInput(_ device: AudioDevice?) {
        preferredInputUID = device?.uid
        persist()
        reconcile()
    }

    func selectOutput(_ device: AudioDevice?) {
        preferredOutputUID = device?.uid
        persist()
        reconcile()
    }

    func selectMonitor(_ device: AudioDevice?) {
        preferredMonitorUID = device?.uid
        persist()
        reconcile()
    }

    func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleMute) { [weak self] in
            guard let self, self.isBridgeEnabled else { return }
            self.toggleMute()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleMonitor) { [weak self] in
            guard let self, self.isBridgeEnabled else { return }
            self.toggleMonitor()
        }
    }

    private func handleDeviceListChanged() {
        devices = deviceManager.allDevices()
        reconcile()
    }

    /// preferred UID → 有効な device、および稼働状態を再計算する。
    /// デバイスの抜き差しに追従してブリッジを自動停止/再開する。
    private func reconcile() {
        let newInput = preferredInputUID.flatMap { uid in devices.first { $0.uid == uid } }
        let newOutput = preferredOutputUID.flatMap { uid in devices.first { $0.uid == uid } }
        let newMonitor = preferredMonitorUID.flatMap { uid in devices.first { $0.uid == uid } }

        let devicesChanged =
            newInput?.uid != inputDevice?.uid ||
            newOutput?.uid != outputDevice?.uid ||
            newMonitor?.uid != monitorDevice?.uid

        inputDevice = newInput
        outputDevice = newOutput
        monitorDevice = newMonitor

        let canRun = userWantsBridgeRunning && isAudioAllowed && newInput != nil && newOutput != nil
        if canRun {
            if !isBridgeEnabled || devicesChanged {
                teardownBridge()
                startBridgeInternal()
            }
        } else if isBridgeEnabled {
            teardownBridge()
        }
    }

    private func applyActiveDevicesFromPreferred() {
        inputDevice = preferredInputUID.flatMap { uid in devices.first { $0.uid == uid } }
        outputDevice = preferredOutputUID.flatMap { uid in devices.first { $0.uid == uid } }
        monitorDevice = preferredMonitorUID.flatMap { uid in devices.first { $0.uid == uid } }
    }

    private func startBridgeInternal() {
        guard let input = inputDevice, let output = outputDevice else { return }
        do {
            try bridge.start(
                inputDeviceID: input.id,
                outputDeviceID: output.id,
                monitorDeviceID: monitorDevice?.id
            )
            applyAudibility()
            isBridgeEnabled = true
            errorMessage = nil
        } catch {
            errorMessage = "ブリッジ起動に失敗: \(error.localizedDescription)"
            isBridgeEnabled = false
            bridge.stop()
        }
    }

    private func teardownBridge() {
        bridge.stop()
        isBridgeEnabled = false
        inputLevel = 0
    }

    private func persist() {
        defaults.set(preferredInputUID, forKey: Keys.inputUID)
        defaults.set(preferredOutputUID, forKey: Keys.outputUID)
        defaults.set(preferredMonitorUID, forKey: Keys.monitorUID)
        defaults.set(userWantsBridgeRunning, forKey: Keys.wasEnabled)
        defaults.set(isMonitorEnabled, forKey: Keys.monitorEnabled)
    }
}

extension KeyboardShortcuts.Name {
    static let toggleMute = Self(
        "toggleMute",
        default: .init(.m, modifiers: [.control, .option, .shift])
    )
    static let toggleMonitor = Self(
        "toggleMonitor",
        default: .init(.n, modifiers: [.control, .option, .shift])
    )
}
