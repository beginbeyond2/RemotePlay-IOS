//
//  VideoDisplayView.swift
//  RemotePlay
//
//  使用 AVSampleBufferDisplayLayer 实时显示解码后的 H.264 帧。
//  对应 Android 端 SurfaceView + MediaCodec 配置 surface。
//
//  关键：AVSampleBufferDisplayLayer 必须是 UIView 的 root layer（layerClass override），
//       不能作为 sublayer 添加。iOS 26 的 runtime 检查更严格，
//       用 addSublayer 会在收到第一帧时崩溃。
//

import SwiftUI
import AVFoundation
import VideoToolbox
import CoreMedia

/// SwiftUI 包装：将 UIView（含 AVSampleBufferDisplayLayer 作为 root layer）嵌入布局。
struct VideoDisplayView: UIViewRepresentable {
    @EnvironmentObject private var viewModel: RemotePlayViewModel

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        // 解码器把渲染目标设置为该 layer（root layer = AVSampleBufferDisplayLayer）
        viewModel.bind(displayLayer: view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // 不需要主动更新；新帧由 ViewModel -> Decoder -> Layer 推送
    }
}

/// 含 AVSampleBufferDisplayLayer 作为 root layer 的容器 UIView。
/// 对应 Android 端 SurfaceView。
/// v2.2.6 修复：让 AVSampleBufferDisplayLayer 作为 root layer，而不是 sublayer。
final class PlayerContainerView: UIView {

    /// 直接让 root layer 就是 AVSampleBufferDisplayLayer。
    /// AVSampleBufferDisplayLayer 必须是 root level layer，不能 addSublayer。
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    /// 暴露 root layer 供解码器使用。
    var displayLayer: AVSampleBufferDisplayLayer {
        // Swift 在 override layerClass 后会保证 self.layer 是指定类型
        return self.layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureDisplayLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDisplayLayer()
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // root layer 的 frame 等同于 view 的 bounds
        displayLayer.frame = bounds
    }
}
