//
//  RemotePlayApp.swift
//  RemotePlay
//
//  App 入口。锁定横屏，对应 Android 的 screenOrientation="sensorLandscape"。
//

import SwiftUI

@main
struct RemotePlayApp: App {

    // 整个进程内共享的 ViewModel
    @StateObject private var viewModel = RemotePlayViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}
