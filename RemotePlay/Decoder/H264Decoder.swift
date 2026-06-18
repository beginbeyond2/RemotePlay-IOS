//
//  H264Decoder.swift
//  RemotePlay
//
//  使用 VideoToolbox 硬解 H.264，得到 CVPixelBuffer，
//  再用 CMSampleBufferCreateForImageBuffer 构造 iOS 18+ 合规的
//  sample buffer，enqueue 到 AVSampleBufferDisplayLayer 实时显示。
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
//  v2.3.0 重大修复：使用 @convention(c) 全局回调，避免 Swift 编译器
//  在 "outputCallback: nil" + "closure-based VTDecompressionSessionDecodeFrame"
//  混用时的 overload 解析失败。
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

// 顶层 @convention(c) 回调函数（VTDecompressionSessionCreate 要求）
// 不能捕获 Swift context，所以通过 refcon 拿到 H264Decoder 实例。
private let vtOutputCallback: VTDecompressionOutputCallback = {
    (refcon, status, _, imageBuffer, pts, _) in
    guard let refcon = refcon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()
    if status != noErr {
        NSLog("H264Decoder: VT callback status=\(status)")
        return
    }
    guard let pb = imageBuffer else { return }
    decoder.enqueuePixelBuffer(pb, presentationTime: pts)
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

    /// 推入一段 Annex-B 格式的 H.264 数据（含 0x00 0x00 0x00 0x01 start code）。
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
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }

        // 拆分 NALU（同时支持 4 字节和 3 字节 start code）。
        var i = 0
        var naluStart = -1
        var nalus: [(type: UInt8, body: Data)] = []

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

        // 第一遍：收集 SPS / PPS
        for nalu in nalus {
            if nalu.type == 0x07 {
                spsData = nalu.body
            } else if nalu.type == 0x08 {
                ppsData = nalu.body
            }
        }

        // 如果 format description 还没建好，先建
        if formatDescription == nil, let sps = spsData, let pps = ppsData {
            createFormatDescription(sps: sps, pps: pps)
        }

        // 第二遍：解码 VCL NALU（IDR/P/B 等）
        guard let fmt = formatDescription, let session = decompressionSession else { return }
        for nalu in nalus where nalu.type != 0x07 && nalu.type != 0x08 {
            decode(nalu: nalu.body, format: fmt, session: session)
        }
    }

    private func createFormatDescription(sps: Data, pps: Data) {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var format: CMVideoFormatDescription?

        let status = spsBytes.withUnsafeBufferPointer { spsPtr -> OSStatus in
            ppsBytes.withUnsafeBufferPointer { ppsPtr -> OSStatus in
                let paramSet: [UnsafePointer<UInt8>] = [
                    UnsafePointer(spsPtr.baseAddress!),
                    UnsafePointer(ppsPtr.baseAddress!)
                ]
                let paramSizes = [spsBytes.count, ppsBytes.count]
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

        // 创建 VTDecompressionSession（必须用 @convention(c) 回调）
        if let session = makeDecompressionSession(format: fmt) {
            self.decompressionSession = session
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.decoderDidChangeVideoSize(size)
            }
        }
    }

    private func makeDecompressionSession(format: CMVideoFormatDescription) -> VTDecompressionSession? {
        // v2.3.0 修复：用顶层 @convention(c) 回调 + passUnretained refcon
        // 之前 v2.2.8 用了 outputCallback: nil + closure-based decode，
        // Swift 编译器无法 resolve overload。
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: vtOutputCallback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            NSLog("H264Decoder: VTDecompressionSessionCreate failed: \(status)")
            return nil
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // 记录 refcon 供 decode 时用（passUnretained 必须保 self 不被释放）
        // 实际由 VideoDisplayView 强引用 H264Decoder 维持生命周期
        _ = refcon

        return s
    }

    private func decode(nalu: Data, format: CMVideoFormatDescription, session: VTDecompressionSession) {
        // 把 nalu 数据包成 CMBlockBuffer
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

        // v2.3.1 修复：用 &-operator 写法，Swift 5.5+ 自动把 inout 转 UnsafePointer。
        // 之前 v2.3.0 用了 sampleSize.withUnsafeMutablePointer，但 Int / CMSampleTimingInfo
        // 是值类型，没有这个实例方法，编译错误。
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
        // v2.3.0 修复：使用同步版本（不带 closure），因为 callback 已在
        // session 创建时指定（vtOutputCallback）。通过 frameRefcon 把 self 传给 callback。
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
