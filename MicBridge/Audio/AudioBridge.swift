import AVFoundation
import CoreAudio
import Foundation

enum AudioBridgeError: LocalizedError {
    case setDeviceFailed(OSStatus, String)
    case engineStartFailed(String)
    case audioUnitUnavailable
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case let .setDeviceFailed(status, role):
            return "\(role) デバイス設定失敗 (OSStatus=\(status))"
        case let .engineStartFailed(role):
            return "\(role) エンジンの起動に失敗"
        case .audioUnitUnavailable:
            return "AudioUnit を取得できませんでした"
        case .invalidFormat:
            return "オーディオフォーマットが無効です"
        }
    }
}

final class AudioBridge {
    private var inputEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var monitorEngine: AVAudioEngine?

    private var outputMixer: AVAudioMixerNode?
    private var monitorMixer: AVAudioMixerNode?
    private var outputRing: AudioRingBuffer?
    private var monitorRing: AudioRingBuffer?

    private(set) var isRunning = false

    /// リングバッファ容量（フレーム）。48kHz なら約 85ms 分。
    /// レイテンシではなく overrun 耐性のための容量なので、大きめに取っても OK。
    private static let ringCapacityFrames = 4096

    /// デバイスに要求する I/O バッファサイズ。128 frames @ 48kHz ≒ 2.7ms。
    private static let preferredDeviceBufferFrames: UInt32 = 128

    func start(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        monitorDeviceID: AudioDeviceID?
    ) throws {
        stop()

        // --- Input engine ---
        let inputEngine = AVAudioEngine()
        try setDevice(engine: inputEngine, isInput: true, deviceID: inputDeviceID, role: "入力")
        let inputFormat = inputEngine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioBridgeError.engineStartFailed("入力（フォーマット取得失敗）")
        }
        guard !inputFormat.isInterleaved else {
            throw AudioBridgeError.invalidFormat
        }
        let channelCount = Int(inputFormat.channelCount)

        // --- Ring buffers ---
        let outputRing = AudioRingBuffer(
            capacityFrames: Self.ringCapacityFrames,
            channelCount: channelCount
        )
        let monitorRing: AudioRingBuffer? = (monitorDeviceID != nil)
            ? AudioRingBuffer(capacityFrames: Self.ringCapacityFrames, channelCount: channelCount)
            : nil

        // --- Output engine ---
        let outputEngine = AVAudioEngine()
        try setDevice(engine: outputEngine, isInput: false, deviceID: outputDeviceID, role: "出力")
        let outputSource = AVAudioSourceNode(format: inputFormat) { [outputRing] _, _, frameCount, ablPtr in
            outputRing.read(into: ablPtr, frames: Int(frameCount))
            return noErr
        }
        outputEngine.attach(outputSource)
        let outputMixer = outputEngine.mainMixerNode
        outputEngine.connect(outputSource, to: outputMixer, format: inputFormat)

        // --- Monitor engine ---
        var monitorEngineOptional: AVAudioEngine?
        var monitorMixerOptional: AVAudioMixerNode?
        if let monitorID = monitorDeviceID, let ring = monitorRing {
            let engine = AVAudioEngine()
            try setDevice(engine: engine, isInput: false, deviceID: monitorID, role: "モニター")
            let source = AVAudioSourceNode(format: inputFormat) { [ring] _, _, frameCount, ablPtr in
                ring.read(into: ablPtr, frames: Int(frameCount))
                return noErr
            }
            engine.attach(source)
            let mixer = engine.mainMixerNode
            engine.connect(source, to: mixer, format: inputFormat)
            monitorEngineOptional = engine
            monitorMixerOptional = mixer
        }

        // --- Input sink ---
        let sink = AVAudioSinkNode { [outputRing, monitorRing] _, frameCount, ablPtr in
            let frames = Int(frameCount)
            outputRing.write(from: ablPtr, frames: frames)
            monitorRing?.write(from: ablPtr, frames: frames)
            return noErr
        }
        inputEngine.attach(sink)
        inputEngine.connect(inputEngine.inputNode, to: sink, format: inputFormat)

        // --- Start engines ---
        outputEngine.prepare()
        do { try outputEngine.start() } catch { throw AudioBridgeError.engineStartFailed("出力") }

        if let monitorEngine = monitorEngineOptional {
            monitorEngine.prepare()
            do { try monitorEngine.start() } catch { throw AudioBridgeError.engineStartFailed("モニター") }
        }

        inputEngine.prepare()
        do { try inputEngine.start() } catch { throw AudioBridgeError.engineStartFailed("入力") }

        self.inputEngine = inputEngine
        self.outputEngine = outputEngine
        self.monitorEngine = monitorEngineOptional
        self.outputMixer = outputMixer
        self.monitorMixer = monitorMixerOptional
        self.outputRing = outputRing
        self.monitorRing = monitorRing
        self.isRunning = true
    }

    func stop() {
        outputEngine?.stop()
        monitorEngine?.stop()
        inputEngine?.stop()

        inputEngine = nil
        outputEngine = nil
        monitorEngine = nil
        outputMixer = nil
        monitorMixer = nil
        outputRing = nil
        monitorRing = nil
        isRunning = false
    }

    func setOutputMuted(_ muted: Bool) {
        outputMixer?.outputVolume = muted ? 0 : 1
    }

    func setMonitorMuted(_ muted: Bool) {
        monitorMixer?.outputVolume = muted ? 0 : 1
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
        Self.setPreferredBufferFrameSize(
            deviceID: deviceID,
            frames: Self.preferredDeviceBufferFrames
        )
    }

    /// デバイスのハードウェア I/O バッファサイズを短く要求する。
    /// サポート範囲外は暗黙に無視される。
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
