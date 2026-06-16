//
//  RemoteClient.swift
//  RemotePlay
//
//  TCP 客户端，对应 Android 端 SocketThread：
//  - 端口：8888
//  - 下行：[4B frameType][4B frameLen][H.264 data]
//  - 上行：12B 控制指令（由 CommandBuilder 构造）
//
//  使用 Network.framework 的 NWConnection。
//

import Foundation
import Network
import Combine

/// 下行帧。
struct IncomingFrame {
    /// 原始 frameType 4 字节，对应 Android 端 frameTypeByte。
    let typeBytes: Data
    /// 已解码的 type 整数（与 Android 端 frameType 对应）。
    let type: UInt32
    /// 第二个字节（用于解析 RUN/SEQ/AUTO 状态位）。
    let flags: UInt8
    /// H.264 帧数据。
    let payload: Data
}

/// 客户端状态。
enum RemoteClientState: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}

/// 远程示波器 TCP 客户端。
final class RemoteClient {
    typealias FrameHandler = (IncomingFrame) -> Void
    typealias StateHandler = (RemoteClientState) -> Void

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.micsig.tbook.remoteplay.client")
    private var connection: NWConnection?
    private var stateHandler: StateHandler?
    private var frameHandler: FrameHandler?

    /// 接收缓冲区。
    private var receiveBuffer = Data()

    /// 是否已调用过 start。
    private var started = false

    init(host: String, port: UInt16 = 8888) {
        self.host = host
        self.port = port
    }

    deinit { cancel() }

    func setHandlers(state: @escaping StateHandler, frame: @escaping FrameHandler) {
        self.stateHandler = state
        self.frameHandler = frame
    }

    /// 启动连接。
    func start() {
        guard !started else { return }
        started = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            stateHandler?(.failed("Invalid port"))
            started = false
            return
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        self.connection = conn

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.noDelay = true
        // 8MB 接收缓冲，对应 Android 端 setReceiveBufferSize(8 * 1024 * 1024)
        tcpOptions.receiveBufferSize = 8 * 1024 * 1024
        tcpOptions.maximumSegmentSize = 1400

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .responsiveData
        conn.parameters = parameters

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateHandler?(.connected)
                self.startReceiving()
            case .failed(let err):
                self.stateHandler?(.failed(err.localizedDescription))
                self.cancel()
            case .cancelled:
                self.stateHandler?(.idle)
            case .waiting(let err):
                self.stateHandler?(.failed("waiting: \(err.localizedDescription)"))
            default:
                break
            }
        }

        stateHandler?(.connecting)
        conn.start(queue: queue)
    }

    /// 关闭连接。
    func cancel() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        started = false
    }

    /// 发送 12 字节上行指令。
    /// 对应 Android 端 SendThread。
    func send(_ data: Data) {
        guard let conn = connection, conn.state == .ready else { return }
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                NSLog("RemoteClient send error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - 接收循环

    private func startReceiving() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainFrames()
            }
            if let error {
                self.stateHandler?(.failed(error.localizedDescription))
                self.cancel()
                return
            }
            if isComplete {
                self.cancel()
                return
            }
            // 继续接收
            self.startReceiving()
        }
    }

    /// 解析缓冲区中的完整帧。
    /// 对应 Android 端：
    ///   recvX(frameTypeByte, 4); frameType = byteArrayToInt(frameTypeByte);
    ///   recvX(frameLenByte, 4);   frameLen  = byteArrayToInt(frameLenByte);
    ///   recvX(frameData, frameLen); onFrame(frameData, 0, frameLen);
    private func drainFrames() {
        while receiveBuffer.count >= 8 {
            let typeBytes = receiveBuffer.prefix(4)
            let lenBytes = receiveBuffer.subdata(in: 4..<8)
            let frameLen = lenBytes.withUnsafeBytes { ptr -> UInt32 in
                let p = ptr.bindMemory(to: UInt8.self)
                return UInt32(p[0]) |
                       (UInt32(p[1]) << 8) |
                       (UInt32(p[2]) << 16) |
                       (UInt32(p[3]) << 24)
            }

            // 防御：避免恶意 / 异常长度撑爆内存
            if frameLen > 8 * 1024 * 1024 {
                stateHandler?(.failed("frame too large: \(frameLen)"))
                cancel()
                return
            }

            let totalNeeded = 8 + Int(frameLen)
            if receiveBuffer.count < totalNeeded { break }

            let payload = receiveBuffer.subdata(in: 8..<totalNeeded)
            receiveBuffer.removeFirst(totalNeeded)

            let typeInt = typeBytes.withUnsafeBytes { ptr -> UInt32 in
                let p = ptr.bindMemory(to: UInt8.self)
                return UInt32(p[0]) |
                       (UInt32(p[1]) << 8) |
                       (UInt32(p[2]) << 16) |
                       (UInt32(p[3]) << 24)
            }

            let frame = IncomingFrame(
                typeBytes: Data(typeBytes),
                type: typeInt,
                flags: typeBytes[1],
                payload: payload
            )
            frameHandler?(frame)
        }
    }
}
