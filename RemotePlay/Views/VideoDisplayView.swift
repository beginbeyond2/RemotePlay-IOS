//
//  VideoDisplayView.swift
//  RemotePlay
//
//  使用 AVSampleBufferDisplayLayer 实时显示解码后的 H.264 帧。
//  对应 Android 端 SurfaceView + MediaCodec 配置 surface。
//

import SwiftUI
import AVFoundation
import VideoToolbox
import CoreMedia

/// SwiftUI 包装：将 UIView（含 AVSampleBufferDisplayLayer）嵌入布局。
struct VideoDisplayView: UIViewRepresentable {
    @EnvironmentObject private var viewModel: RemotePlayViewModel

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        // 解码器把渲染目标设置为该 layer
        viewModel.bind(displayLayer: view.sampleBufferDisplayLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // 不需要主动更新；新帧由 ViewModel -> Decoder -> Layer 推送
    }
}

/// 含 AVSampleBufferDisplayLayer 的容器 UIView。
/// 对应 Android 端 SurfaceView。
final class PlayerContainerView: UIView {
    let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()

    override class var layerClass: AnyClass { CALayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        sampleBufferDisplayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(sampleBufferDisplayLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleBufferDisplayLayer.frame = bounds
    }
}
