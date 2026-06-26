//
//  H264Decoder.swift
//  RemotePlay
//
//  v2.3.16 视频黑屏修复：
//    1) `nalUnitHeaderLength: 4` → `1`（Annex-B 格式参数集）
//    2) 去掉多余的 `CMVideoFormatDescriptionCreateForImageBuffer`
//       直接传 nil 给 `CMSampleBufferCreateForImageBuffer`（自动提取 format）
//    3) `CVPixelBufferLockBaseAddress` / `UnlockBaseAddress` 锁住 pixel buffer
//    4) 加大量 NSLog 让远程诊断可以定位问题
//
//  对应 Android 端：
//    mMediaCodec = MediaCodec.createDecoderByType("video/avc");
//    mMediaCodec.configure(mediaFormat, surface, null, 0);   // surface mode
//    mMediaCodec.start();
//    mMediaCodec.queueInputBuffer(...);                       // 喂 H.264 帧
//    mMediaCodec.dequeueOutputBuffer(...);                    // 取解码结果
//    mMediaCodec.releaseOutputBuffer(idx, true);              // 渲染到 surface
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

    weak var delegate: H264DecoderDelegate?

    private let displayLayer: AVSampleBufferDisplayLayer
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private let decodeQueue = DispatchQueue(label: "com.micsig.tbook.remoteplay.h264decoder")
    private var frameIndex: UInt64 = 0
    private var displayedFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private let pixelBufferAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
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

    fileprivate func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        NSLog("H264Decoder: enqueuePixelBuffer called, pts=\(presentationTime.value)/\(presentationTime.timescale)")

        // 锁住 pixel buffer（让多线程安全使用）
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        if lockStatus != kCVReturnSuccess {
            NSLog("H264Decoder: CVPixelBufferLockBaseAddress failed: \(lockStatus)")
        }

        defer {
            let unlockStatus = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            if unlockStatus != kCVReturnSuccess {
                NSLog("H264Decoder: CVPixelBufferUnlockBaseAddress failed: \(unlockStatus)")
            }
        }

        // 直接用 CMSampleBufferCreateForImageBuffer，formatDescription 传 nil 让其自动从 image buffer 提取
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,   // ← 自动从 image buffer 提取
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else {
            NSLog("H264Decoder: CMSampleBufferCreateForImageBuffer failed: \(status)")
            return
        }

        // 投递到主线程 enqueue
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.enqueue(sb)
                self.displayedFrameCount += 1
                NSLog("H264Decoder: enqueued frame #\(self.displayedFrameCount), pts=\(presentationTime.value)/\(presentationTime.timescale), isReady=Y")
            } else {
                // Layer 不 ready，flush + 重试
                self.displayLayer.flush()
                if self.displayLayer.isReadyForMoreMediaData {
                    self.displayLayer.enqueue(sb)
                    self.displayedFrameCount += 1
                    NSLog("H264Decoder: enqueued after flush #\(self.displayedFrameCount)")
                } else {
                    self.droppedFrameCount += 1
                    NSLog("H264Decoder: displayLayer still not ready, dropped frame #\(self.droppedFrameCount)")
                }
            }
        }
    }

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
            let nalu = Array(bytes[naluStart..<bytes.count])
            if let type = nalu.first {
                nalus.append((type: type, body: nalu))
            }
        }

        NSLog("H264Decoder: parsed \(nalus.count) nalus (input bytes=\(bytes.count), hasSPS=\(spsData != nil), hasPPS=\(ppsData != nil), hasSession=\(decompressionSession != nil))")

        // 第一遍：收集 SPS / PPS
        for nalu in nalus {
            if nalu.type == 0x07 {
                spsData = Data(nalu.body)
                NSLog("H264Decoder: SPS updated, size=\(nalu.body.count)")
            } else if nalu.type == 0x08 {
                ppsData = Data(nalu.body)
                NSLog("H264Decoder: PPS updated, size=\(nalu.body.count)")
            }
        }

        // 如有 SPS+PPS 且 session 还没建 → 建
        if let sps = spsData, let pps = ppsData, formatDescription == nil {
            NSLog("H264Decoder: have SPS(\(sps.count) bytes) + PPS(\(pps.count) bytes), creating session...")
            makeFormatDescription(sps: Array(sps), pps: Array(pps))
        }

        // 第二遍：解码 VCL NALU
        guard let fmt = formatDescription, let session = decompressionSession else {
            if !nalus.isEmpty {
                NSLog("H264Decoder: no session yet, dropping \(nalus.count) nalus")
            }
            return
        }
        for nalu in nalus where nalu.type != 0x07 && nalu.type != 0x08 {
            decode(nalu: nalu.body, format: fmt, session: session)
        }
    }

    private func makeFormatDescription(sps: [UInt8], pps: [UInt8]) {
        var format: CMVideoFormatDescription?

        // v2.3.16 修复：参数集是 Annex-B 格式（无 4 字节 length prefix），
        // 应该传 nalUnitHeaderLength: 1（1 字节 NALU type header）。
        // 之前 v2.3.0 ~ v2.3.15 传 4 是 AVCC 格式值，导致 format description 构造失败。
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
                            nalUnitHeaderLength: 1,  // ← Annex-B 格式：1 字节 NALU type header
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }

        guard status == noErr, let fmt = format else {
            NSLog("H264Decoder: format description failed: \(status)")
            return
        }
        self.formatDescription = fmt

        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let size = CGSize(width: Int(dims.width), height: Int(dims.height))
        NSLog("H264Decoder: video size \(Int(dims.width))x\(Int(dims.height))")

        // 建 VTDecompressionSession
        if makeDecompressionSession(format: fmt) {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.decoderDidChangeVideoSize(size)
            }
        }
    }

    private func makeDecompressionSession(format: CMVideoFormatDescription) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: VTDecompressionOutputCallback = H264Decoder.vtOutputCallback
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: refcon
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            NSLog("H264Decoder: VTDecompressionSessionCreate failed: \(status)")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = s
        NSLog("H264Decoder: VTDecompressionSession created OK")
        return true
    }

    private func decode(nalu: [UInt8], format: CMVideoFormatDescription, session: VTDecompressionSession) {
        // 把 nalu 数据包成 CMBlockBuffer（送进 VTDecompressionSession）
        var blockBuffer: CMBlockBuffer?
        let dataLength = nalu.count
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
            NSLog("H264Decoder: CMBlockBufferCreate failed: \(createStatus)")
            return
        }

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
            return
        }

        // 包成 CMSampleBuffer（送进 VTDecompressionSession）
        var sampleBuffer: CMSampleBuffer?
        var sampleSize: Int = dataLength
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: 25),
            decodeTimeStamp: .invalid
        )
        let buildStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard buildStatus == noErr, let sb = sampleBuffer else {
            NSLog("H264Decoder: CMSampleBufferCreateReady failed: \(buildStatus)")
            return
        }

        frameIndex &+= 1

        // 提交到 VTDecompressionSession 解码
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [],
            frameRefcon: refcon,
            infoFlagsOut: nil
        )
        if status != noErr {
            NSLog("H264Decoder: VTDecompressionSessionDecodeFrame failed: \(status)")
        }
    }
}

// 静态 @convention(c) 回调：VTDecompressionSession 的解码完成 callback。
// Apple SDK 中 VTDecompressionOutputCallback 的真实签名是 7 参数。
extension H264Decoder {
    static let vtOutputCallback: VTDecompressionOutputCallback = {
        (refcon, sourceFrameRefCon, status, infoFlags, imageBuffer, pts, duration) in
        guard let refcon = refcon else { return }
        guard status == noErr else {
            NSLog("H264Decoder: VT callback status=\(status), infoFlags=\(infoFlags.rawValue)")
            return
        }
        guard let pb = imageBuffer else { return }
        let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
        decoder.enqueuePixelBuffer(pb, presentationTime: pts)
    }
}