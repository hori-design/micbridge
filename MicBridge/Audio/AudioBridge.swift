import AVFoundation
import CoreAudio
import Foundation

enum AudioBridgeError: LocalizedError {
    case setDeviceFailed(OSStatus, String)
    case engineStartFailed(String)
    case audioUnitUnavailable

    var errorDescription: String? {
        switch self {
        case let .setDeviceFailed(status, role):
            return "\(role) デバイス設定失敗 (OSStatus=\(status))"
        case let .engineStartFailed(role):
            return "\(role) エンジンの起動に失敗"
        case .audioUnitUnavailable:
            return "AudioUnit を取得できませんでした"
        }
    }
}

final class AudioBridge {
    private var inputEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var monitorEngine: AVAudioEngine?

    private var outputPlayer: AVAudioPlayerNode?
    private var monitorPlayer: AVAudioPlayerNode?
    private var outputMixer: AVAudioMixerNode?

    private(set) var isRunning = false

    var onLevelUpdate: ((Float) -> Void)?

    func start(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        monitorDeviceID: AudioDeviceID?
    ) throws {
        stop()

        let inputEngine = AVAudioEngine()
        try setDevice(engine: inputEngine, isInput: true, deviceID: inputDeviceID, role: "入力")
        let inputFormat = inputEngine.inputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioBridgeError.engineStartFailed("入力（フォーマット取得失敗）")
        }

        let outputEngine = AVAudioEngine()
        try setDevice(engine: outputEngine, isInput: false, deviceID: outputDeviceID, role: "出力")
        let outputPlayer = AVAudioPlayerNode()
        outputEngine.attach(outputPlayer)
        let outputMixer = outputEngine.mainMixerNode
        outputEngine.connect(outputPlayer, to: outputMixer, format: inputFormat)

        var monitorEngine: AVAudioEngine?
        var monitorPlayer: AVAudioPlayerNode?
        if let monitorID = monitorDeviceID {
            let engine = AVAudioEngine()
            try setDevice(engine: engine, isInput: false, deviceID: monitorID, role: "モニター")
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: inputFormat)
            monitorEngine = engine
            monitorPlayer = player
        }

        inputEngine.inputNode.installTap(
            onBus: 0,
            bufferSize: 256,
            format: inputFormat
        ) { [weak self, weak outputPlayer, weak monitorPlayer] buffer, _ in
            if let player = outputPlayer, player.engine != nil {
                player.scheduleBuffer(buffer, completionHandler: nil)
            }
            if let player = monitorPlayer, player.engine != nil {
                player.scheduleBuffer(buffer, completionHandler: nil)
            }
            if let handler = self?.onLevelUpdate {
                let level = Self.rmsLevel(from: buffer)
                DispatchQueue.main.async { handler(level) }
            }
        }

        outputEngine.prepare()
        do {
            try outputEngine.start()
        } catch {
            throw AudioBridgeError.engineStartFailed("出力")
        }
        outputPlayer.play()

        if let monitorEngine, let monitorPlayer {
            monitorEngine.prepare()
            do {
                try monitorEngine.start()
            } catch {
                throw AudioBridgeError.engineStartFailed("モニター")
            }
            monitorPlayer.play()
        }

        inputEngine.prepare()
        do {
            try inputEngine.start()
        } catch {
            throw AudioBridgeError.engineStartFailed("入力")
        }

        self.inputEngine = inputEngine
        self.outputEngine = outputEngine
        self.monitorEngine = monitorEngine
        self.outputPlayer = outputPlayer
        self.monitorPlayer = monitorPlayer
        self.outputMixer = outputMixer
        self.isRunning = true
    }

    func stop() {
        if let inputEngine {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
        }
        outputPlayer?.stop()
        outputEngine?.stop()
        monitorPlayer?.stop()
        monitorEngine?.stop()

        inputEngine = nil
        outputEngine = nil
        monitorEngine = nil
        outputPlayer = nil
        monitorPlayer = nil
        outputMixer = nil
        isRunning = false
    }

    func setMuted(_ muted: Bool) {
        outputMixer?.outputVolume = muted ? 0 : 1
    }

    private static func rmsLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sumSquares += sample * sample
            }
        }
        let mean = sumSquares / Float(frameLength * channelCount)
        return sqrt(mean)
    }

    private func setDevice(
        engine: AVAudioEngine,
        isInput: Bool,
        deviceID: AudioDeviceID,
        role: String
    ) throws {
        let node = isInput ? engine.inputNode : engine.outputNode
        guard let audioUnit = node.audioUnit else {
            throw AudioBridgeError.audioUnitUnavailable
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw AudioBridgeError.setDeviceFailed(status, role)
        }
        Self.setPreferredBufferFrameSize(deviceID: deviceID, frames: 128)
    }

    /// デバイスのハードウェア I/O バッファサイズを短く要求する。
    /// デバイスがサポート範囲外の場合は暗黙に無視される。
    private static func setPreferredBufferFrameSize(deviceID: AudioDeviceID, frames: UInt32) {
        var value = frames
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
    }
}
