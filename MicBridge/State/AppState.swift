import AppKit
import Combine
import CoreAudio
import Foundation
import KeyboardShortcuts

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var inputDevice: AudioDevice?
    @Published private(set) var outputDevice: AudioDevice?
    @Published private(set) var monitorDevice: AudioDevice?
    @Published private(set) var isBridgeEnabled = false
    @Published var isMuted = false
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
    }

    init() {
        preferredInputUID = defaults.string(forKey: Keys.inputUID)
        preferredOutputUID = defaults.string(forKey: Keys.outputUID)
        preferredMonitorUID = defaults.string(forKey: Keys.monitorUID)
        userWantsBridgeRunning = defaults.bool(forKey: Keys.wasEnabled)

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
        bridge.setMuted(isMuted)
        if isMuted { inputLevel = 0 }
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
            bridge.setMuted(isMuted)
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
    }
}

extension KeyboardShortcuts.Name {
    static let toggleMute = Self(
        "toggleMute",
        default: .init(.m, modifiers: [.control, .option, .shift])
    )
}
