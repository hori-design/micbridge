import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool
}

extension Notification.Name {
    static let audioDeviceListChanged = Notification.Name("MicBridge.audioDeviceListChanged")
}

final class AudioDeviceManager {
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isObserving = false

    func allDevices() -> [AudioDevice] {
        deviceIDs().compactMap(deviceInfo)
    }

    private func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func deviceInfo(for id: AudioDeviceID) -> AudioDevice? {
        let name = stringProperty(id: id, selector: kAudioObjectPropertyName) ?? "Unknown Device"
        let uid = stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID) ?? "unknown-\(id)"
        let hasInput = channelCount(id: id, scope: kAudioObjectPropertyScopeInput) > 0
        let hasOutput = channelCount(id: id, scope: kAudioObjectPropertyScopeOutput) > 0
        guard hasInput || hasOutput else { return nil }
        return AudioDevice(id: id, name: name, uid: uid, hasInput: hasInput, hasOutput: hasOutput)
    }

    private func stringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfString as String
    }

    private func channelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferListPtr) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr.assumingMemoryBound(to: AudioBufferList.self))
        var total = 0
        for buffer in bufferList {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }

    func startObservingDeviceChanges() {
        guard !isObserving else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            NotificationCenter.default.post(name: .audioDeviceListChanged, object: nil)
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        isObserving = true
    }
}
