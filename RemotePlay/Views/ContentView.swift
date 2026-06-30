//
//  ContentView.swift
//  RemotePlay
//
//  根视图。横向 HStack：左侧视频区，右侧控制栏。
//  对应 Android layout/activity_main.xml 的 LinearLayout 横向布局。
//

import SwiftUI

/// onChange 跨 iOS 16 / iOS 17 兼容包装器。
/// - iOS 17：使用新签名 `onChange(of:) { oldValue, newValue in ... }`
/// - iOS 16：使用旧签名 `onChange(of:) { newValue in ... }`
@available(iOS 16.0, *)
extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value) { newValue in
                action(newValue)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var viewModel: RemotePlayViewModel
    @StateObject private var logStore = LogStore.shared
    @State private var showLogSheet = false

    var body: some View {
        GeometryReader { geo in
            // 与 Android 端 layout-large 风格保持一致：
            // 视频区:控制栏 ≈ 2:1
            HStack(spacing: 0) {
                videoArea
                    .frame(maxWidth: .infinity)
                    .layoutPriority(2)
                ControlPanelView()
                    .frame(width: max(180, geo.size.height * 0.22))
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .ignoresSafeArea()
        .onAppear {
            viewModel.loadSavedIP()
            viewModel.startIfPossible()
        }
        .onDisappear {
            viewModel.stop()
        }
        .sheet(isPresented: $showLogSheet) {
            LogSheetView()
                .environmentObject(logStore)
        }
    }

    /// 视频显示区域：含 logo 遮罩 + AVSampleBufferDisplayLayer 渲染 + 触摸层。
    private var videoArea: some View {
        GeometryReader { videoGeo in
            ZStack {
                VideoDisplayView()
                    .environmentObject(viewModel)

                TouchCaptureView { screenPoint, phase in
                    viewModel.handleTouch(at: screenPoint, phase: phase)
                }
                .allowsHitTesting(true)

                if !viewModel.isConnected {
                    LogoOverlayView()
                        .transition(.opacity)
                }

                VStack {
                    if let msg = viewModel.toastMessage {
                        Text(msg)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundColor(.white)
                            .padding(.top, 24)
                    }
                    HStack {
                        // v2.3.18: [DEBUG] 按钮，显示 LogStore 日志
                        Button {
                            showLogSheet = true
                        } label: {
                            Text("DEBUG")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundColor(.white)
                        }
                        .padding(.top, 8)
                        .padding(.leading, 12)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .background(Color(uiColor: UIColor(white: 0.1, alpha: 1.0)))
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                viewModel.updateSurfaceSize(videoGeo.size)
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChangeCompat(of: videoGeo.size) { newSize in
                viewModel.updateSurfaceSize(newSize)
            }
        }
    }
}

/// v2.3.18: 日志显示弹窗
/// v2.3.38: 重写为 VStack，不依赖 navigationBar toolbar（iOS 26 toolbar 不可靠），
/// 让 Copy 按钮绝对可见。
struct LogSheetView: View {
    @EnvironmentObject private var logStore: LogStore
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedToast = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部按钮栏（v2.3.35：不依赖 toolbar）
                HStack(spacing: 12) {
                    Button("Clear") { logStore.clear() }
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)

                    // v2.3.35：大 Copy 按钮（黄色加粗 + 蓝底 + 📋 emoji）
                    // v2.3.40 修复：用 setItems 替代直接赋值 .string（iOS 26 更可靠）
                    Button(action: {
                        let allText = logStore.dumpAll()
                        // 1) 写文件到 Documents/RemotePlay-log.txt（已有，3uTools 可导出）
                        if let url = LogStore.shared.getFileURL() {
                            try? allText.data(using: .utf8)?.write(to: url, options: .atomic)
                        }
                        // 2) 用 setItems 复制到剪贴板（iOS 26 兼容）
                        UIPasteboard.general.setItems([
                            [UIPasteboard.typeAutomatic: allText]
                        ])
                        showCopiedToast = true
                    }) {
                        HStack {
                            Image(systemName: "doc.on.doc.fill")
                            Text("COPY (\(logStore.lines.count) 行)")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(.yellow)
                        .background(Color.blue.opacity(0.6))
                        .cornerRadius(8)
                    }

                    // v2.3.42：用 SwiftUI ShareLink 替代 UIActivityViewController
                    // SwiftUI ShareLink 是 iOS 16+ 原生组件，在 .sheet 内能正确弹分享菜单
                    if let url = LogStore.shared.getFileURL() {
                        ShareLink(item: url) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("SHARE FILE")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundColor(.white)
                            .background(Color.green.opacity(0.7))
                            .cornerRadius(8)
                        }
                        // 点击时强制写一次文件，保证最新
                        .simultaneousGesture(TapGesture().onEnded {
                            let allText = logStore.dumpAll()
                            try? allText.data(using: .utf8)?.write(to: url, options: .atomic)
                        })
                    }

                    Button("Close") { dismiss() }
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black)

                // 日志滚动区
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(logStore.lines.enumerated()), id: \.offset) { (idx, line) in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(colorFor(line))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .background(Color.black)
                    .onChangeCompat(of: logStore.lines.count) { _ in
                        if let last = logStore.lines.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("DEBUG LOG (v2.3.49 · \(logStore.lines.count))")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("已复制 \(logStore.lines.count) 行到剪贴板 + 写入 Documents/RemotePlay-log.txt")
                        .padding(8)
                        .background(Color.green.opacity(0.85))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 30)
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func colorFor(_ line: String) -> Color {
        if line.contains("failed") || line.contains("error") || line.contains("Error") {
            return .red
        }
        if line.contains("created OK") || line.contains("enqueued") {
            return .green
        }
        if line.contains("skipped") {
            return .yellow
        }
        return .gray
    }
}

/// 触摸捕获视图。
struct TouchCaptureView: View {
    let onTouch: (CGPoint, TouchPhase) -> Void

    enum TouchPhase { case began, moved, ended }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onTouch(value.location, .moved)
                    }
                    .onEnded { value in
                        onTouch(value.location, .ended)
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onTouch(value.location, .began)
                    }
            )
    }
}

/// 启动时显示的 Logo + "Micsig" 文字遮罩。
struct LogoOverlayView: View {
    var body: some View {
        ZStack {
            Color(uiColor: UIColor(white: 0.1, alpha: 1.0))
            VStack(spacing: 16) {
                Text("Micsig")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .italic()
                    .foregroundColor(Color(red: 0.27, green: 0.62, blue: 0.94))
                Image(systemName: "waveform.path.ecg")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 120)
                    .foregroundColor(Color(red: 0.0, green: 0.70, blue: 0.90))
            }
        }
    }
}
