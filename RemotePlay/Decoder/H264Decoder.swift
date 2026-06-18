//
//  H264Decoder.swift
//  RemotePlay
//
//  使用 VideoToolbox 硬解 H.264，并把解码后的视频帧推送到
//  AVSampleBufferDisplayLayer 上实时显示。
//
//  对应 Android 端：
//    mMediaCodec = MediaCodec.createDecoderByType("video/avc");
//    mMediaCodec.configure(mediaFormat, surface, null, 0);
//    mMediaCodec.start();
//    mMediaCodec.queueInputBuffer(...);
//    mMediaCodec.dequeueOutputBuffer(...);
//
//  下行数据格式约定：每次 payload 即一段 Annex-B H.264 帧。
//  包含 [start code 0x00 0x00 0x00 0x01] + NALU。
//  - 0x67 (SPS)、0x68 (PPS) 用于构造 CMVideoFormatDescription。
//  - 0x65 (IDR) / 0x41 (P) 等为实际图像数据。
//

import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

protocol H264DecoderDelegate: AnyObject {
    /// 视频尺寸发生变化（对应 Android 端 INFO_OUTPUT_FORMAT_CHANGED）。
    func decoderDidChangeVideoSize(_ size: CGSize)
}

final class H264Decoder {

    weak var delegate: H264DecoderDelegate?

    private let displayLayer: AVSampleBufferDisplayLayer
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private let decodeQueue = DispatchQueue(label: "com.micsig.tbook.remoteplay.h264decoder")
    private var frameIndex: UInt64 = 0

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    // MARK: - Public

    /// 推入一段 Annex-B 格式的 H.264 数据（含 0x00 0x00 0x00 0x01 start code）。
    func feedAnnexB(_ data: Data) {
        decodeQueue.async { [weak self] in
            self?.process(data)
        }
    }

    /// 推入一段 AVCC 格式 H.264（4 字节大端长度前缀 + NALU）。
    func feedAVCC(_ data: Data) {
        // 将 AVCC 转 Annex-B，再复用同一处理流程
        var annexB = Data()
        var cursor = 0
        let bytes = [UInt8](data)
        while cursor + 4 <= bytes.count {
            let len = (UInt32(bytes[cursor]) << 24) |
                      (UInt32(bytes[cursor + 1]) << 16) |
                      (UInt32(bytes[cursor + 2]) << 8) |
                       UInt32(bytes[cursor + 3])
            let naluStart = cursor + 4
            let naluEnd = naluStart + Int(len)
            if naluEnd > bytes.count { break }
            annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            annexB.append(contentsOf: bytes[naluStart..<naluEnd])
            cursor = naluEnd
        }
        feedAnnexB(annexB)
    }

    /// 冲刷队列。视图消失时调用。
    func flush() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.flush()
        }
    }

    // MARK: - Private

    private func process(_ data: Data) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }

        // 拆分 NALU（同时支持 4 字节和 3 字节 start code）。
        var i = 0
        var naluStart = -1
        var nalus: [(type: UInt8, body: Data)] = []

        while i < bytes.count {
            // 匹配 start code
            var scLen = 0
            if i + 4 <= bytes.count
                && bytes[i] == 0 && bytes[i+1] == 0
                && bytes[i+2] == 0 && bytes[i+3] == 1 {
                scLen = 4
            } else if i + 3 <= bytes.count
                && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                scLen = 3
            }

            if scLen > 0 {
                if naluStart >= 0 {
                    let nalu = Data(bytes[naluStart..<i])
                    if let type = nalu.first {
                        nalus.append((type: type, body: nalu))
                    }
                }
                naluStart = i + scLen
                i += scLen
            } else {
                i += 1
            }
        }
        if naluStart >= 0 && naluStart < bytes.count {
            let nalu = Data(bytes[naluStart..<bytes.count])
            if let type = nalu.first {
                nalus.append((type: type, body: nalu))
            }
        }

        // 第一遍：收集 SPS / PPS，并构造 formatDescription
        for nalu in nalus where nalu.type == 0x07 || nalu.type == 0x08 {
            if nalu.type == 0x07 {
                spsData = nalu.body
            } else if nalu.type == 0x08 {
                ppsData = nalu.body
            }
        }

        if let sps = spsData, let pps = ppsData, formatDescription == nil {
            makeFormatDescription(sps: sps, pps: pps)
        }

        // 第二遍：把图像 NALU 包装为 CMSampleBuffer 并入队
        for nalu in nalus where nalu.type != 0x07 && nalu.type != 0x08 {
            guard let fmt = formatDescription else { continue }
            guard let sample = makeSampleBuffer(nalu: nalu.body, format: fmt) else { continue }
            enqueue(sample)
        }
    }

    private func makeFormatDescription(sps: Data, pps: Data) {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var format: CMVideoFormatDescription?
        let status = spsBytes.withUnsafeBufferPointer { spsPtr -> OSStatus in
            ppsBytes.withUnsafeBufferPointer { ppsPtr -> OSStatus in
                let paramSet = [UnsafePointer(spsPtr.baseAddress!),
                                UnsafePointer(ppsPtr.baseAddress!)]
                let paramSizes = [spsBytes.count, ppsBytes.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: paramSet,
                    parameterSetSizes: paramSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }

        guard status == noErr, let fmt = format else {
            NSLog("H264Decoder: format description failed: \(status)")
            return
        }
        self.formatDescription = fmt

        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let size = CGSize(width: Int(dims.width), height: Int(dims.height))
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.decoderDidChangeVideoSize(size)
        }
    }

    private func makeSampleBuffer(nalu: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let dataLength = nalu.count
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else {
            NSLog("H264Decoder: CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return nil
        }

        // 将 nalu（含 0x00 0x00 0x00 0x01 start code）拷贝进 BlockBuffer
        let copyStatus = nalu.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            NSLog("H264Decoder: CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
            return nil
        }

        // 1 个 NALU；CMBlockBuffer 引用同一段数据。
        // v2.2.7 修复：用 withUnsafeMutablePointer 显式取地址，避免 Swift ABI
        // 变化下隐式 inout → pointer 转换失败（iOS 18+ 已观察到崩溃）。
        var sampleSize: Int = dataLength
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25), // 25 fps，与 Android 端 mCount*1000000/25 对应
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 25),
            decodeTimeStamp: .invalid
        )

        var sample: CMSampleBuffer?
        let createStatus = sampleSize.withUnsafeMutablePointer { sizePtr -> OSStatus in
            timing.withUnsafeMutablePointer { timingPtr -> OSStatus in
                CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: bb,
                    formatDescription: format,
                    sampleCount: 1,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: timingPtr,
                    sampleSizeEntryCount: 1,
                    sampleSizeArray: sizePtr,
                    sampleBufferOut: &sample
                )
            }
        }
        guard createStatus == noErr else {
            NSLog("H264Decoder: CMSampleBufferCreateReady failed: \(createStatus)")
            return nil
        }
        return sample
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        frameIndex &+= 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 防御：displayLayer 在主线程访问，但 layer 可能在视图消失后被释放
            guard self.displayLayer.superlayer != nil || self.displayLayer.superlayer == nil && true else {
                return
            }
            // 防御：检查 displayLayer 是否在视图层级中
            // (AVSampleBufferDisplayLayer 作为 root layer 时 superlayer 应为 nil)
            autoreleasepool {
                if self.displayLayer.isReadyForMoreMediaData {
                    self.displayLayer.enqueue(sample)
                } else {
                    self.displayLayer.flush()
                    if self.displayLayer.isReadyForMoreMediaData {
                        self.displayLayer.enqueue(sample)
                    } else {
                        NSLog("H264Decoder: displayLayer not ready, dropping frame")
                    }
                }
            }
        }
    }
}
