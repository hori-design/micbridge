import AVFoundation
import Foundation
import os

/// Single-Producer / Single-Consumer 前提の non-interleaved Float32 リングバッファ。
/// - 書き手はオーディオ入力スレッド (AVAudioSinkNode の receiverBlock)
/// - 読み手はオーディオ出力スレッド (AVAudioSourceNode の renderBlock)
/// 出力側が読み出せる分が無いときは 0 で埋める（underrun）。
/// 入力側が書き込む余地がないときは古いフレームを捨てる（overrun）。
final class AudioRingBuffer: @unchecked Sendable {
    let capacityFrames: Int
    let channelCount: Int

    private var storage: [UnsafeMutablePointer<Float>]
    private var writeFrame: Int = 0
    private var readFrame: Int = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacityFrames: Int, channelCount: Int) {
        precondition(capacityFrames > 0)
        precondition(channelCount > 0)
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        self.storage = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            return p
        }
    }

    deinit {
        for p in storage {
            p.deinitialize(count: capacityFrames)
            p.deallocate()
        }
    }

    /// AudioBufferList (non-interleaved) から N フレームを書き込む。
    func write(from audioBufferList: UnsafePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        let mutablePtr = UnsafeMutablePointer<AudioBufferList>(mutating: audioBufferList)
        let bufferList = UnsafeMutableAudioBufferListPointer(mutablePtr)
        let srcBufferCount = bufferList.count

        lock.lock()
        defer { lock.unlock() }

        for i in 0..<frames {
            let dstIndex = (writeFrame + i) % capacityFrames
            for c in 0..<channelCount {
                let srcC = min(c, srcBufferCount - 1)
                if srcC >= 0, let data = bufferList[srcC].mData?.assumingMemoryBound(to: Float.self) {
                    storage[c][dstIndex] = data[i]
                } else {
                    storage[c][dstIndex] = 0
                }
            }
        }
        writeFrame += frames

        // overrun: capacity を超えたら古い側を落とす
        let available = writeFrame - readFrame
        if available > capacityFrames {
            readFrame = writeFrame - capacityFrames
        }
    }

    /// AudioBufferList (non-interleaved) に N フレーム読み出す。
    /// 蓄積不足なら 0 で埋める。
    func read(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let dstBufferCount = bufferList.count

        lock.lock()
        defer { lock.unlock() }

        let available = max(0, writeFrame - readFrame)
        let toCopy = min(frames, available)

        for c in 0..<dstBufferCount {
            guard let dst = bufferList[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let srcC = min(c, channelCount - 1)
            if srcC >= 0 {
                for i in 0..<toCopy {
                    let srcIndex = (readFrame + i) % capacityFrames
                    dst[i] = storage[srcC][srcIndex]
                }
            } else {
                for i in 0..<toCopy { dst[i] = 0 }
            }
            for i in toCopy..<frames {
                dst[i] = 0
            }
        }
        readFrame += toCopy
    }
}
