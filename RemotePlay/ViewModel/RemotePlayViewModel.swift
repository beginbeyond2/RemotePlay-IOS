//
//  RemotePlayViewModel.swift
//  RemotePlay
//
//  状态机 + 业务中枢。对应 Android 端 MainActivity。
//  - 网络：RemoteClient（NWConnection TCP）
//  - 解码：H264Decoder（VideoToolbox）
//  - 渲染：AVSampleBufferDisplayLayer（由 VideoDisplayView 提供）
//  - 持久化：UserDefaults（key = "RemotePlay.ip"）
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

/// 按钮高亮状态，对应 Android 端 MSG_RUN/STOP/SINGLE_RUN/SINGLE_STOP/AUTO_RUN/AUTO_STOP。
/// 使用 SwiftUI Color 便于与 UI 集成。
struct IndicatorState: Equatable {
    enum Kind { case run, single, auto }

    let text: String
    let color: Color

    static let runStop = IndicatorState(text: "RUN/STOP", color: .white)
    static let runOn   = IndicatorState(text: "RUN/STOP", color: .green)
    static let runOff  = IndicatorState(text: "STOP",    color: .red)

    static func make(_ kind: Kind, on: Bool) -> IndicatorState {
        let c: Color = on ? .green : .white
        switch kind {
        case .run:    return IndicatorState(text: on ? "RUN/STOP" : "STOP", color: on ? .green : .red)
        case .single: return IndicatorState(text: "SEQ",  color: c)
        case .auto:   return IndicatorState(text: "AUTO", color: c)
        }
    }
}

@MainActor
final class RemotePlayViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var toastMessage: String?
    @Published private(set) var runState: IndicatorState = .runStop
    @Published private(set) var singleState: IndicatorState = IndicatorState(text: "SEQ", color: .white)
    @Published private(set) var autoState: IndicatorState = IndicatorState(text: "AUTO", color: .white)
    @Published private(set) var ip: String = ""

    // MARK: - Private

    private let userDefaultsKey = "RemotePlay.ip"
    private var client: RemoteClient?
    private var decoder: H264Decoder?
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var videoSize: CGSize = CGSize(width: 800, height: 600)
    private var surfaceSize: CGSize = .zero
    private var toastClearWorkItem: DispatchWorkItem?

    // MARK: - Lifecycle

    init() {}

    /// SwiftUI 视图层在创建 PlayerContainerView 后调用一次，把渲染层注入进来。
    func bind(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        if decoder == nil {
            let d = H264Decoder(displayLayer: displayLayer)
            d.delegate = self
            self.decoder = d
        }
    }

    /// 读取上次保存的 IP。
    /// 对应 Android 端 getString() / SharedPreferences.getString("ip", "")。
    func loadSavedIP() {
        let stored = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        self.ip = stored
    }

    /// 更新 IP 并持久化。
    /// 对应 Android 端 putString() / Editor.putString.commit()。
    func updateIP(_ newIP: String) {
        self.ip = newIP
        UserDefaults.standard.set(newIP, forKey: userDefaultsKey)
    }

    /// 如果 IP 非空则启动连接。
    /// 对应 Android 端 startSocket()。
    func startIfPossible() {
        guard !ip.isEmpty else { return }
        connect()
    }

    /// 主动停止（视图消失 / onPause 等）。
    /// 对应 Android 端 onPause()。
    func stop() {
        client?.cancel()
        client = nil
        decoder?.flush()
        setConnected(false)
    }

    private func connect() {
        stop() // 先断开
        let c = RemoteClient(host: ip, port: 8888)
        c.setHandlers { [weak self] state in
            DispatchQueue.main.async { self?.handleState(state) }
        } frame: { [weak self] frame in
            DispatchQueue.main.async { self?.handleFrame(frame) }
        }
        self.client = c
        c.start()
    }

    // MARK: - State / Frame

    private func handleState(_ state: RemoteClientState) {
        switch state {
        case .connected:
            setConnected(true)
            showToast(NSLocalizedString("Connection Success", comment: ""))
        case .failed(let err):
            setConnected(false)
            showToast(NSLocalizedString("Connection Break", comment: "") + " (\(err))")
        case .connecting:
            setConnected(false)
        case .idle:
            setConnected(false)
        }
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        if !value {
            runState = .runStop
            singleState = IndicatorState(text: "SEQ", color: .white)
            autoState = IndicatorState(text: "AUTO", color: .white)
        }
    }

    /// 处理下行帧。对应 Android 端 SocketThread.run() 中的 flags 解析与 onFrame()。
    private func handleFrame(_ frame: IncomingFrame) {
        let b = frame.flags
        // 与 Android 端位运算保持一致
        if (b >> 7) & 0x01 == 0x01 {
            if runState != .runOn { runState = .runOn }
        } else {
            if runState != .runOff { runState = .runOff }
        }
        if (b >> 5) & 0x01 == 0x01 {
            if singleState != IndicatorState(text: "SEQ", color: .green) {
                singleState = IndicatorState(text: "SEQ", color: .green)
            }
        } else {
            if singleState != IndicatorState(text: "SEQ", color: .white) {
                singleState = IndicatorState(text: "SEQ", color: .white)
            }
        }
        if (b >> 2) & 0x01 == 0x01 {
            if autoState != IndicatorState(text: "AUTO", color: .green) {
                autoState = IndicatorState(text: "AUTO", color: .green)
            }
        } else {
            if autoState != IndicatorState(text: "AUTO", color: .white) {
                autoState = IndicatorState(text: "AUTO", color: .white)
            }
        }

        decoder?.feedAnnexB(frame.payload)
    }

    private func showToast(_ text: String) {
        toastMessage = text
        toastClearWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastClearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Touch / Button

    /// 处理视频区触摸事件。screenPoint 已经是本地图形坐标（0..width, 0..height），
    /// 在调用方（TouchCaptureView）传入；这里负责映射到视频原始尺寸。
    func handleTouch(at point: CGPoint, phase: TouchCaptureView.TouchPhase) {
        guard isConnected else { return }
        guard videoSize.width > 0, videoSize.height > 0,
              surfaceSize.width > 0, surfaceSize.height > 0 else { return }
        let vw = videoSize.width
        let vh = videoSize.height
        let sw = surfaceSize.width
        let sh = surfaceSize.height
        let x = Int(point.x * vw / sw)
        let y = Int(point.y * vh / sh)
        switch phase {
        case .began, .moved:
            client?.send(CommandBuilder.touch(x: x, y: y, pressDown: true))
        case .ended:
            client?.send(CommandBuilder.touch(x: x, y: y, pressDown: false))
        }
    }

    /// 视频 SurfaceView 实际像素尺寸，由 SwiftUI 容器在 layout 阶段更新。
    func updateSurfaceSize(_ size: CGSize) {
        self.surfaceSize = size
    }

    /// 按钮按下。
    func onButton(_ code: RemoteButtonCode) {
        guard isConnected else { return }
        // up / down 在 Android 端是组合 clickPoint，iOS 端等价
        switch code {
        case .up:
            // 对应 Android up 按钮：连续 4 个 clickPoint
            emitMenuSequence(yPoints: [560, 550, 540, 510], press: [true, true, true, false])
        case .down:
            // 对应 Android down 按钮：连续 4 个 clickPoint
            emitMenuSequence(yPoints: [20, 30, 40, 50], press: [true, true, true, false])
        default:
            client?.send(CommandBuilder.button(code: code.rawValue, pressDown: true))
        }
    }

    /// 按钮抬起。
    func onButtonRelease(_ code: RemoteButtonCode) {
        guard isConnected else { return }
        if code == .up || code == .down { return } // up/down 自身序列已经处理 press=false
        client?.send(CommandBuilder.button(code: code.rawValue, pressDown: false))
    }

    private func emitMenuSequence(yPoints: [Int], press: [Bool]) {
        // x=videoWidth*200/800，y 缩放到 600 分之一
        let x = Int(videoSize.width) * 200 / 800
        for (i, yRaw) in yPoints.enumerated() {
            let y = Int(videoSize.height) * yRaw / 600
            client?.send(CommandBuilder.touch(x: x, y: y, pressDown: press[i]))
        }
    }
}

extension RemotePlayViewModel: H264DecoderDelegate {
    func decoderDidChangeVideoSize(_ size: CGSize) {
        self.videoSize = size
    }
}
