//
//  H264Decoder.swift
//  RemotePlay
//
//  v2.3.8 重写：使用 VideoToolbox 硬解 H.264（VTDecompressionSession），
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
//  v2.3.7 编译错误原因：
//    1) `outputCallback:` 期望 UnsafePointer<VTDecompressionOutputCallbackRecord>?
//       （不是 @convention(c) function pointer）。Swift 在 VideoToolbox SDK 里把
//       callback 包装成 VTDecompressionOutputCallbackRecord struct（含 function
//       pointer + refcon）。v2.3.7 直接传 closure 类型，编译失败。
//    2) spsData/ppsData 是 Data?，nalu.body 是 [UInt8]，不能直接赋值。
//    3) paramSetPtr.baseAddress 是 UnsafePointer? 可选，需要 force unwrap。
//
//  v2.3.8 修复：
//    1) 用 VTDecompressionOutputCallbackRecord struct 包装 callback + refcon。
//    2) 显式 Data(nalu.body) 转换。
//    3) baseAddress! force unwrap。
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

        // 第一遍：收集 SPS / PPS（v2.3.8: 显式转 Data 类型）
        for nalu in nalus {
            if nalu.type == 0x07 {
                spsData = Data(nalu.body)
            } else if nalu.type == 0x08 {
                ppsData = Data(nalu.body)
            }
        }

        // 如有 SPS+PPS 且 session 还没建 → 建（v2.3.8: 转 [UInt8] 给 makeFormatDescription）
        if let sps = spsData, let pps = ppsData, formatDescription == nil {
            makeFormatDescription(sps: Array(sps), pps: Array(pps))
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
                            parameterSetPointers: paramSetPtr.baseAddress!,
                            parameterSetSizes: paramSizesPtr.baseAddress!,
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
        // v2.3.9: outputCallback 期望 UnsafePointer<VTDecompressionOutputCallbackRecord>?
        // Swift 把 callback + refcon 包装在 VTDecompressionOutputCallbackRecord struct 里。
        // 必须用 struct 的 init 或直接构造 record，不能直接传 @convention(c) closure。
        // v2.3.8 用 var callbackRecord = VTDecompressionOutputCallbackRecord(...) 时
        // 编译器报"type of expression is ambiguous"，因为 closure + optional 参数推不出类型。
        // v2.3.9 加显式类型注解 : VTDecompressionOutputCallbackRecord。
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
}

// v2.3.7：把 extension 放在 class 声明之后。
// 静态 @convention(c) 回调：VTDecompressionSession 的解码完成 callback。
// 必须用 @convention(c) 因为 VideoToolbox API 期望 C 函数指针。
// 通过 refcon（UnsafeMutableRawPointer）拿回 H264Decoder 实例。
extension H264Decoder {
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
