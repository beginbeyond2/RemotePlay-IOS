//
//  H264Decoder.swift
//  RemotePlay
//
//  v2.3.5 重写：使用 VideoToolbox 硬解 H.264（VTDecompressionSession），
//  拿到 CVPixelBuffer 后用 CMSampleBufferCreateForImageBuffer 构造
//  iOS 18+ 合规的 sample buffer，enqueue 到 AVSampleBufferDisplayLayer。
//
//  对应 Android 端：
//    mMediaCodec = MediaCodec.createDecoderByType("video/avc");
//    mMediaCodec.configure(mediaFormat, surface, null, 0);
//    mMediaCodec.start();
//    mMediaCodec.queueInputBuffer(...);
//    mMediaCodec.dequeueOutputBuffer(...);
//
//  下行数据格式：Annex-B H.264（含 0x00 0x00 0x00 0x01 start code）。
//  - 0x67 (SPS)、0x68 (PPS) 用于构造 CMVideoFormatDescription。
//  - 0x65 (IDR) / 0x41 (P) 等为实际图像数据。
//
//  之前 v2.2.6 用 CMBlockBuffer 创建 CMSampleBuffer 直接 enqueue，
//  iOS 18+ 上 AVSampleBufferDisplayLayer 会静默丢帧（视频不显示）。
//  v2.3.0 / v2.3.1 试图用 VTDecompressionSession 重写但有编译错误。
//  v2.3.5 用 @convention(c) callback + &-operator 避免之前所有编译错误。
//

import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

protocol H264DecoderDelegate: AnyObject {
    func decoderDidChangeVideoSize(_ size: CGSize)
}

// v2.3.6 改用 final class 静态方法作为 @convention(c) 回调
// Swift 中 closure literal 初始化 @convention(c) 类型的顶级 let，
// 编译器在某些 Swift 版本可能报"无法推断类型"或"C 函数指针不能有 capture"。
// 用 static func + @convention(c) 注解是更可靠的方式。
extension H264Decoder {
    /// VTDecompressionSession 的解码完成回调。
    /// 必须用 @convention(c) 因为 VideoToolbox API 期望 C 函数指针。
    /// 通过 refcon（OpaquePointer）拿回 H264Decoder 实例。
    static let vtOutputCallback: @convention(c) (
        UnsafeMutableRawPointer?, OSStatus, UInt32, CVImageBuffer?, CMTime, CMTime
    ) -> Void = { refcon, status, _, imageBuffer, pts, _ in
        guard let refcon = refcon else { return }
        guard status == noErr else {
            NSLog("H264Decoder: VT callback status=\(status)")
            return
        }
        guard let pb = imageBuffer else { return }
        let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
        decoder.enqueuePixelBuffer(pb, presentationTime: pts)
    }
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

        NSLog("H264Decoder: parsed \(nalus.count) nalus")

        // 第一遍：收集 SPS / PPS
        for nalu in nalus {
            if nalu.type == 0x07 {
                spsData = nalu.body
            } else if nalu.type == 0x08 {
                ppsData = nalu.body
            }
        }

        // 如有 SPS+PPS 且 session 还没建 → 建
        if let sps = spsData, let pps = ppsData, formatDescription == nil {
            makeFormatDescription(sps: sps, pps: pps)
        }

        // 第二遍：解码 VCL NALU
        guard let fmt = formatDescription, let session = decompressionSession else {
            NSLog("H264Decoder: no session yet, dropping VCL nalus")
            return
        }
        for nalu in nalus where nalu.type != 0x07 && nalu.type != 0x08 {
            decode(nalu: nalu.body, format: fmt, session: session)
        }
    }

    private func makeFormatDescription(sps: [UInt8], pps: [UInt8]) {
        var format: CMVideoFormatDescription?

        // 用 &-operator（Swift 5.5+ 自动转 UnsafePointer），不用 withUnsafeMutablePointer
        // 关键：parameterSetPointers 只传一次
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
                            parameterSetPointers: paramSetPtr.baseAddress,
                            parameterSetSizes: paramSizesPtr.baseAddress,
                            nalUnitHeaderLength: 4,
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
        // v2.3.5 关键：用 @convention(c) 回调（C 函数形式）
        // 之前 v2.2.8 用了 outputCallback: nil + closure-based decode，
        // Swift 编译器无法 resolve overload。
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: H264Decoder.vtOutputCallback,
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
        // 用 &-operator 写法（Swift 5.5+ 自动 inout -> UnsafePointer 转换）
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
        // 用同步版本（不带 closure），callback 已在 session 创建时指定
        // 通过 frameRefcon 把 self 传给 callback
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

    fileprivate func enqueuePixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        // 用 pixel buffer 构造 CMVideoFormatDescription
        var fmt: CMVideoFormatDescription?
        let status1 = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &fmt
        )
        guard status1 == noErr, let format = fmt else {
            NSLog("H264Decoder: CMVideoFormatDescriptionCreateForImageBuffer failed: \(status1)")
            return
        }

        // 用 pixel buffer 构造 CMSampleBuffer（iOS 18+ 合规形式）
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 25),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        let status2 = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status2 == noErr, let sb = sampleBuffer else {
            NSLog("H264Decoder: CMSampleBufferCreateForImageBuffer failed: \(status2)")
            return
        }

        // 标记数据 ready
        CMSampleBufferMakeDataReady(sb)

        // 投递到主线程 enqueue
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.enqueue(sb)
            } else {
                self.displayLayer.flush()
                if self.displayLayer.isReadyForMoreMediaData {
                    self.displayLayer.enqueue(sb)
                } else {
                    NSLog("H264Decoder: displayLayer still not ready, dropping frame")
                }
            }
        }
    }
}
