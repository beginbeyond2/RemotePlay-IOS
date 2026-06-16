//
//  ControlPanelView.swift
//  RemotePlay
//
//  右侧控制栏。包含：RUN/STOP、SEQ、AUTO、50%、HOME、MENU、UP 共 7 个按钮，
//  以及 IP 输入框。对应 Android layout/activity_main.xml 中右侧 LinearLayout。
//

import SwiftUI

struct ControlPanelView: View {
    @EnvironmentObject private var viewModel: RemotePlayViewModel
    @State private var ipDraft: String = ""
    @FocusState private var ipFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            RemoteButton(
                title: viewModel.runState.text,
                color: viewModel.runState.color,
                onTouch: { viewModel.onButton(.run) },
                onRelease: { viewModel.onButtonRelease(.run) }
            )
            RemoteButton(
                title: "SEQ",
                color: viewModel.singleState.color,
                onTouch: { viewModel.onButton(.single) },
                onRelease: { viewModel.onButtonRelease(.single) }
            )
            RemoteButton(
                title: "AUTO",
                color: viewModel.autoState.color,
                onTouch: { viewModel.onButton(.auto) },
                onRelease: { viewModel.onButtonRelease(.auto) }
            )
            RemoteButton(
                title: "50%",
                color: .white,
                onTouch: { viewModel.onButton(.half) },
                onRelease: { viewModel.onButtonRelease(.half) }
            )
            RemoteIconButton(
                systemName: "house.fill",
                onTouch: { viewModel.onButton(.home) },
                onRelease: { viewModel.onButtonRelease(.home) }
            )
            RemoteButton(
                title: "MENU",
                color: .white,
                onTouch: { viewModel.onButton(.down) },
                onRelease: { viewModel.onButtonRelease(.down) }
            )
            RemoteIconButton(
                systemName: "arrow.up.circle.fill",
                onTouch: { viewModel.onButton(.up) },
                onRelease: { viewModel.onButtonRelease(.up) }
            )
            Spacer()
            ipInput
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.40, blue: 0.60),
                         Color(red: 0.31, green: 0.51, blue: 0.74)],
                startPoint: .top, endPoint: .bottom
            )
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
struct RemoteButton: View {
    let title: String
    let color: Color
    let onTouch: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed
                          ? Color(red: 0.27, green: 0.62, blue: 0.94)
                          : LinearGradient(
                                colors: [Color(red: 0.27, green: 0.62, blue: 0.94),
                                         Color(red: 0.18, green: 0.40, blue: 0.60)],
                                startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(red: 0.18, green: 0.40, blue: 0.60), lineWidth: 1)
                    )
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onTouch() }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

/// 图标按钮（如 HOME / UP），使用 SF Symbols。
/// 对应 Android 的 ImageButton + drawable/ic_home / ic_up。
struct RemoteIconButton: View {
    let systemName: String
    let onTouch: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(pressed
                          ? Color(red: 0.27, green: 0.62, blue: 0.94)
                          : LinearGradient(
                                colors: [Color(red: 0.27, green: 0.62, blue: 0.94),
                                         Color(red: 0.18, green: 0.40, blue: 0.60)],
                                startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(red: 0.18, green: 0.40, blue: 0.60), lineWidth: 1)
                    )
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onTouch() }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}
