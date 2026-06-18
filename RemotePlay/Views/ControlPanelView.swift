//
//  ControlPanelView.swift
//  RemotePlay
//
//  右侧控制栏。包含：RUN/STOP、SEQ、AUTO、50%、HOME、MENU、UP 共 7 个按钮，
//  以及 IP 输入框。对应 Android layout/activity_main.xml 中右侧 LinearLayout。
//
//  适配：iPhone 11 (~414pt 横屏高) ~ iPhone 17 Pro Max (~430pt 横屏高)。
//  所有尺寸参数从 GeometryReader 动态计算，按比例缩放。
//

import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var viewModel: RemotePlayViewModel
    @State private var ipDraft: String = ""
    @FocusState private var ipFocused: Bool

    var body: some View {
        GeometryReader { geo in
            // 控制栏可用高度（横屏时 ≈ 屏幕高度）
            // 覆盖 iPhone 11 (414pt) ~ iPhone 17 Pro Max (430pt)
            // iPhone SE (375pt) ~ iPad Pro 12.9" (1024pt) 也能自适应
            let h = geo.size.height
            let reservedForFooter: CGFloat = 60.0  // IP 输入框 + padding
            // 7 按钮 + 6 间距 平分剩余高度（h - reserved）
            let buttonH = min(60.0, max(30.0, (h - reservedForFooter) / 8.0))
            // 剩余高度再分给 6 个间距
            let spacing = min(14.0, max(3.0, (h - buttonH * 7 - reservedForFooter) / 8.0))
            // 字体与图标按按钮高度缩放
            let fontSize = min(20.0, max(13.0, buttonH * 0.4))
            let iconSize = min(28.0, max(18.0, buttonH * 0.55))

            VStack(spacing: spacing) {
                Spacer(minLength: 0)

                RemoteButton(
                    title: viewModel.runState.text,
                    color: viewModel.runState.color,
                    height: buttonH,
                    fontSize: fontSize,
                    onTouch: { viewModel.onButton(.run) },
                    onRelease: { viewModel.onButtonRelease(.run) }
                )
                RemoteButton(
                    title: "SEQ",
                    color: viewModel.singleState.color,
                    height: buttonH,
                    fontSize: fontSize,
                    onTouch: { viewModel.onButton(.single) },
                    onRelease: { viewModel.onButtonRelease(.single) }
                )
                RemoteButton(
                    title: "AUTO",
                    color: viewModel.autoState.color,
                    height: buttonH,
                    fontSize: fontSize,
                    onTouch: { viewModel.onButton(.auto) },
                    onRelease: { viewModel.onButtonRelease(.auto) }
                )
                RemoteButton(
                    title: "50%",
                    color: .white,
                    height: buttonH,
                    fontSize: fontSize,
                    onTouch: { viewModel.onButton(.half) },
                    onRelease: { viewModel.onButtonRelease(.half) }
                )
                RemoteIconButton(
                    systemName: "house.fill",
                    height: buttonH,
                    iconSize: iconSize,
                    onTouch: { viewModel.onButton(.home) },
                    onRelease: { viewModel.onButtonRelease(.home) }
                )
                RemoteButton(
                    title: "MENU",
                    color: .white,
                    height: buttonH,
                    fontSize: fontSize,
                    onTouch: { viewModel.onButton(.down) },
                    onRelease: { viewModel.onButtonRelease(.down) }
                )
                RemoteIconButton(
                    systemName: "arrow.up.circle.fill",
                    height: buttonH,
                    iconSize: iconSize,
                    onTouch: { viewModel.onButton(.up) },
                    onRelease: { viewModel.onButtonRelease(.up) }
                )

                Spacer(minLength: 0)
                ipInput
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.40, blue: 0.60),
                         Color(red: 0.31, green: 0.51, blue: 0.74)],
                startPoint: .top, endPoint: .bottom
            )
        )
        // 点击控制栏空白区域（非按钮/输入框）收回键盘
        // 使用 simultaneousGesture 避免吃掉子按钮的事件
        .simultaneousGesture(
            TapGesture().onEnded {
                if ipFocused { ipFocused = false }
            }
        )
        .onAppear { ipDraft = viewModel.ip }
    }

    private var ipInput: some View {
        HStack(spacing: 4) {
            TextField("IP", text: $ipDraft)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .frame(maxWidth: .infinity)
                .focused($ipFocused)
                .onSubmit { commitIP() }
                // iOS decimalPad 没有 Done 键 — 手动加键盘顶部的 Done 工具栏
                // 对应 Android 端 imeOptions="actionDone" 的行为
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            ipFocused = false
                            commitIP()
                        }
                        .fontWeight(.semibold)
                    }
                }
            Button {
                commitIP()
                ipFocused = false
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .imageScale(.large)
            }
        }
        .padding(.top, 4)
    }

    private func commitIP() {
        let trimmed = ipDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.updateIP(trimmed)
        viewModel.startIfPossible()
    }
}

/// 文字按钮。对应 Android Button 配 drawable/button.xml 的蓝色渐变样式。
/// height / fontSize 由父级 ControlPanelView 动态计算并传入，适配不同屏幕。
struct RemoteButton: View {
    let title: String
    let color: Color
    let height: CGFloat
    let fontSize: CGFloat
    let onTouch: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed
                          ? AnyShapeStyle(Color(red: 0.27, green: 0.62, blue: 0.94))
                          : AnyShapeStyle(LinearGradient(
                                colors: [Color(red: 0.27, green: 0.62, blue: 0.94),
                                         Color(red: 0.18, green: 0.40, blue: 0.60)],
                                startPoint: .top, endPoint: .bottom)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(red: 0.18, green: 0.40, blue: 0.60), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // 只在手指仍在按钮内时按下；滑出则取消
                        if isInsideButton(value.location) {
                            if !pressed { pressed = true; onTouch() }
                        } else if pressed {
                            pressed = false; onRelease()
                        }
                    }
                    .onEnded { _ in
                        if pressed { pressed = false; onRelease() }
                    }
            )
    }

    private func isInsideButton(_ point: CGPoint) -> Bool {
        // 因为按钮充满 GeometryReader 宽度，简化判断用 y 坐标
        return point.y >= 0 && point.y <= height
    }
}

/// 图标按钮（如 HOME / UP），使用 SF Symbols。
/// 对应 Android 的 ImageButton + drawable/ic_home / ic_up。
/// height / iconSize 由父级 ControlPanelView 动态计算并传入。
struct RemoteIconButton: View {
    let systemName: String
    let height: CGFloat
    let iconSize: CGFloat
    let onTouch: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed
                          ? AnyShapeStyle(Color(red: 0.27, green: 0.62, blue: 0.94))
                          : AnyShapeStyle(LinearGradient(
                                colors: [Color(red: 0.27, green: 0.62, blue: 0.94),
                                         Color(red: 0.18, green: 0.40, blue: 0.60)],
                                startPoint: .top, endPoint: .bottom)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(red: 0.18, green: 0.40, blue: 0.60), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if isInsideButton(value.location) {
                            if !pressed { pressed = true; onTouch() }
                        } else if pressed {
                            pressed = false; onRelease()
                        }
                    }
                    .onEnded { _ in
                        if pressed { pressed = false; onRelease() }
                    }
            )
    }

    private func isInsideButton(_ point: CGPoint) -> Bool {
        return point.y >= 0 && point.y <= height
    }
}
