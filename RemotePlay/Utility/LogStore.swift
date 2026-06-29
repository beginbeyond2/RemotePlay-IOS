//
//  LogStore.swift
//  RemotePlay
//
//  v2.3.18 - 把所有诊断日志（NSLog）同时写到内存列表 + 文件。
//
//  目的：让用户能在 app 内部看到日志（通过 [DEBUG] 按钮弹窗），
//  解决"iOS 沙盒阻止 3uTools 实时读取 RemotePlay 日志"的问题。
//
//  使用：
//    LogStore.shared.log("RemotePlay: foo=\(bar)")
//  替代：
//    NSLog("RemotePlay: foo=\(bar)")
//
//  两个好处：
//    1) 用户在 app 内的 [DEBUG] 弹窗看日志（截图即可）
//    2) 日志写入 Documents/RemotePlay-log.txt（3uTools 文件共享导出）
//

import Foundation

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var lines: [String] = []
    // v2.3.33 修复：容量 500 → 4000，让 video frame 解析日志不被刷掉。
    // iOS 26 + 25 fps + RemoteClient 12-byte send 频繁出现，500 行 8 秒就满。
    private let maxLines = 4000
    private let fileURL: URL?
    private let dateFormatter: DateFormatter

    private init() {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        self.dateFormatter = df

        // Documents/RemotePlay-log.txt
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.fileURL = docs.appendingPathComponent("RemotePlay-log.txt")
        } else {
            self.fileURL = nil
        }

        // 添加启动标识
        append("[boot] LogStore ready")
    }

    /// 记录一条日志。
    /// - Parameter msg: 任意字符串（建议带前缀 "H264Decoder:" / "RemoteClient:" 等方便筛选）
    nonisolated func log(_ msg: String) {
        let ts = Date()
        let line = "[\(format(ts))] \(msg)"
        NSLog(line)

        // 写文件（后台队列）
        if let url = fileURL {
            DispatchQueue.global(qos: .utility).async {
                if let data = (line + "\n").data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        if let handle = try? FileHandle(forWritingTo: url) {
                            _ = try? handle.seekToEnd()
                            try? handle.write(contentsOf: data)
                            try? handle.close()
                        }
                    } else {
                        try? data.write(to: url, options: .atomic)
                    }
                }
            }
        }

        // 加到 UI 列表
        DispatchQueue.main.async { [weak self] in
            self?.append(line)
        }
    }

    /// 清除内存中的日志（不清文件）。
    func clear() {
        lines.removeAll()
    }

    /// v2.3.33：返回所有日志行（用换行符连接），方便一键复制。
    func dumpAll() -> String {
        return lines.joined(separator: "\n")
    }

    /// v2.3.33：返回日志文件 URL（Documents/RemotePlay-log.txt）。
    /// 用户可用 3uTools 文件共享导出。
    nonisolated func getFileURL() -> URL? {
        return fileURL
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    private nonisolated func format(_ date: Date) -> String {
        return dateFormatter.string(from: date)
    }
}