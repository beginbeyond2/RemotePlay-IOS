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
struct LogSheetView: View {
    @EnvironmentObject private var logStore: LogStore
    @Environment(\.dismiss) private var dismiss
    @State private var showCopiedToast = false

    var body: some View {
        NavigationStack {
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
            .navigationTitle("DEBUG LOG (\(logStore.lines.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") { logStore.clear() }
                        .foregroundColor(.white)
                }
                // v2.3.34：把 Copy 按钮放 principal 位置（中间标题区），一定可见
                ToolbarItem(placement: .principal) {
                    Button("📋 COPY LOG") {
                        UIPasteboard.general.string = logStore.dumpAll()
                        showCopiedToast = true
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.3))
                    .cornerRadius(8)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.white)
                }
            }
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("已复制 \(logStore.lines.count) 行到剪贴板")
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
