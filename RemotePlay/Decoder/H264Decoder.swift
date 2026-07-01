//
//  H264Decoder.swift
//  RemotePlay
//
//  v2.3.50 修复：彻底移除 VTDecompressionSession，直接让 AVSampleBufferDisplayLayer 内部解码。
//  iOS 11+ 起 AVSampleBufferDisplayLayer 可以直接解码 H.264 sample buffer（内部自动管理 VT session）。
//  避免了 VT session 与 pixel buffer attrs 不兼容导致的 -8969 错误。
//
//  流程：
//    1. 从第一帧拆出 SPS/PPS，用 CMVideoFormatDescriptionCreateFromH264ParameterSets 创建 formatDescription
//    2. 每个 NALU（去掉 start code 后）包成 CMBlockBuffer
//    3. 用 CMSampleBufferCreate 创建 sample buffer（带 formatDescription）
//    4. 直接 displayLayer.enqueue(sampleBuffer)
//
//  对应 Android 端：
//    mMediaCodec = MediaCodec.createDecoderByType("video/avc");
//    mMediaCodec.configure(mediaFormat, surface, null, 0);   // surface mode
//    mMediaCodec.start();
//    mMediaCodec.queueInputBuffer(...);
//    mMediaCodec.dequeueOutputBuffer(...);
//    mMediaCodec.releaseOutputBuffer(idx, true);
//

import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

protocol H264DecoderDelegate: AnyObject {
    func decoderDidChangeVideoSize(_ size: CGSize)
}

final class H264Decoder {

    private func writeLog(_ msg: String) {
        LogStore.shared.log("H264Decoder: " + msg)
    }

    weak var delegate: H264DecoderDelegate?

    private let displayLayer: AVSampleBufferDisplayLayer
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private let decodeQueue = DispatchQueue(label: "com.micsig.tbook.remoteplay.h264decoder")
    private var frameIndex: UInt64 = 0
    private var enqueuedFrameCount: UInt64 = 0

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    deinit {
        // 无 VT session 需清理
    }

    // MARK: - Public

    /// 推入一段 Annex-B 格式的 H.264 数据。
    func feedAnnexB(_ data: Data) {
        decodeQueue.async { [weak self] in
            self?.process(data)
        }
    }

    /// 冲刷队列。视图消失时调用。
    func flush() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.flush()
        }
    }

    // MARK: - Private

    private func process(_ data: Data) {
        // 拆 NALU（同时支持 4 字节和 3 字节 start code）
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }

        var i = 0
        var naluStart = -1
        var nalus: [(type: UInt8, body: [UInt8])] = []

        while i < bytes.count {
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
                if naluStart >= 0 && naluStart < i {
                    let nalu = Array(bytes[naluStart..<i])
                    if let first = nalu.first {
                        let naluType = first & 0x1F
                        nalus.append((type: naluType, body: nalu))
                    }
                }
                naluStart = i + scLen
                i += scLen
            } else {
                i += 1
            }
        }
        if naluStart >= 0 && naluStart < bytes.count {
            let nalu = Array(bytes[naluStart..<bytes.count])
            if let first = nalu.first {
                let naluType = first & 0x1F
                nalus.append((type: naluType, body: nalu))
            }
        }

        writeLog("parsed \(nalus.count) nalus (input bytes=\(bytes.count), hasSPS=\(spsData != nil), hasPPS=\(ppsData != nil), hasFormat=\(formatDescription != nil))")

        // 第一遍：收集 SPS / PPS
        for nalu in nalus {
            if nalu.type == 0x07 {
                spsData = Data(nalu.body)
                writeLog("SPS updated, size=\(nalu.body.count)")
            } else if nalu.type == 0x08 {
                ppsData = Data(nalu.body)
                writeLog("PPS updated, size=\(nalu.body.count)")
            }
        }

        // 如有 SPS+PPS 且 formatDescription 还没建 → 建
        if let sps = spsData, let pps = ppsData, formatDescription == nil {
            writeLog("have SPS(\(sps.count) bytes) + PPS(\(pps.count) bytes), creating format description...")
            makeFormatDescription(sps: Array(sps), pps: Array(pps))
        }

        // 第二遍：为每个 VCL NALU（IDR/P帧）创建 sample buffer 并 enqueue
        guard let fmt = formatDescription else {
            if !nalus.isEmpty {
                writeLog("no format description yet, dropping \(nalus.count) nalus")
            }
            return
        }

        for nalu in nalus where nalu.type != 0x07 && nalu.type != 0x08 {
            enqueueNalu(nalu.body, format: fmt)
        }
    }

    private func makeFormatDescription(sps: [UInt8], pps: [UInt8]) {
        var format: CMVideoFormatDescription?

        let status = sps.withUnsafeBufferPointer { spsPtr -> OSStatus in
            pps.withUnsafeBufferPointer { ppsPtr -> OSStatus in
                let paramSet: [UnsafePointer<UInt8>] = [
                    UnsafePointer(spsPtr.baseAddress!),
                    UnsafePointer(ppsPtr.baseAddress!)
                ]
                let paramSizes = [sps.count, pps.count]
                return paramSet.withUnsafeBufferPointer { paramSetPtr -> OSStatus in
                    paramSizes.withUnsafeBufferPointer { paramSizesPtr -> OSStatus in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: paramSetPtr.baseAddress!,
                            parameterSetSizes: paramSizesPtr.baseAddress!,
                            nalUnitHeaderLength: 4,  // AVCC 格式：4 字节 NALU length prefix
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }

        guard status == noErr, let fmt = format else {
            writeLog("format description failed: \(status)")
            return
        }
        self.formatDescription = fmt

        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let size = CGSize(width: Int(dims.width), height: Int(dims.height))
        writeLog("format description created OK, video size \(Int(dims.width))x\(Int(dims.height))")

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.decoderDidChangeVideoSize(size)
        }
    }

    private func enqueueNalu(_ nalu: [UInt8], format: CMVideoFormatDescription) {
        // AVCC 格式：4 字节大端 length prefix + NALU body
        // 对应 Android MediaCodec 的 input buffer 布局（AVCC/NALU-length 格式）
        var avccData = [UInt8]()
        var lengthBE = CFSwapInt32HostToBig(UInt32(nalu.count))
        withUnsafeBytes(of: &lengthBE) { ptr in
            avccData.append(contentsOf: ptr)
        }
        avccData.append(contentsOf: nalu)

        // 把 avccData 包成 CMBlockBuffer
        var blockBuffer: CMBlockBuffer?
        let dataLength = avccData.count
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
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
        guard createStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            writeLog("CMBlockBufferCreate failed: \(createStatus)")
            return
        }

        let copyStatus = avccData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            writeLog("CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
            return
        }

        frameIndex &+= 1

        // 构造 sample buffer（直接让 AVSampleBufferDisplayLayer 解码）
        let ptsValue = CMTimeValue(frameIndex)
        let pts = CMTime(value: ptsValue * 3600, timescale: 90000)  // 1/25 秒
        var sampleSize: Int = dataLength
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime(value: 3600, timescale: 90000),  // 1/25 秒
            presentationTimeStamp: pts,
            decodeTimeStamp: pts
        )
        var sampleBuffer: CMSampleBuffer?
        let buildStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard buildStatus == noErr, let sb = sampleBuffer else {
            writeLog("CMSampleBufferCreate failed: \(buildStatus) pts=\(frameIndex)")
            return
        }

        // 投递到主线程 enqueue
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.enqueue(sb)
                self.enqueuedFrameCount += 1
                self.writeLog("enqueued frame #\(self.enqueuedFrameCount), pts=\(pts.value)/\(pts.timescale)")
            } else {
                self.displayLayer.flush()
                if self.displayLayer.isReadyForMoreMediaData {
                    self.displayLayer.enqueue(sb)
                    self.enqueuedFrameCount += 1
                    self.writeLog("enqueued after flush #\(self.enqueuedFrameCount)")
                } else {
                    self.writeLog("displayLayer not ready after flush, dropping frame")
                }
            }
        }
    }
}