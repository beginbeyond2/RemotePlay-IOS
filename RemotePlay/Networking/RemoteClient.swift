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

    private func writeLog(_ msg: String) { LogStore.shared.log(msg) }
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

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 5
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.noDelay = true
        // 8MB 接收缓冲，对应 Android 端 setReceiveBufferSize(8 * 1024 * 1024)。
        // 注：NWProtocolTCP.Options 在 iOS Network framework 中不暴露
        // receiveBufferSize，操作系统默认缓冲足够处理 H.264 帧。
        tcpOptions.maximumSegmentSize = 1400

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .responsiveData

        // NWConnection.parameters 是只读，必须在构造时传入 using: 参数。
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            // v2.3.36：每个 state 变化都打 log，远程诊断连接状态
            self?.writeLog("RemoteClient state: \(state)")
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

        writeLog("RemoteClient start: connecting to \(host):\(port)")
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
    ///
    /// v2.3.13 修复：撤掉 `conn.state == .ready` 检查。
    ///
    /// 之前 v2.2.9 加的 state check 有 bug：conn.state 由 network framework
    /// 内部队列更新，send 时（client 队列上）可能仍是 .preparing/.setup，
    /// 导致所有 send 被 silently skipped。Android 端没这个 check，
    /// 直接 send。
    ///
    /// NWConnection.send 内部会自己处理：如果不在 ready，content 会被
    /// 缓冲或返回 error callback。**绝不**在 client 端做 state 判断。
    func send(_ data: Data) {
        guard let conn = connection else {
            writeLog("RemoteClient send skipped: no connection")
            return
        }
        writeLog("RemoteClient send: \(data.count) bytes")
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                self.writeLog("RemoteClient send error: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - 接收循环

    private func startReceiving() {
        guard let conn = connection else { return }
        writeLog("RemoteClient startReceiving: max=64K")
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.writeLog("RemoteClient received: \(data.count) bytes (buffer=\(self.receiveBuffer.count + data.count))")
                self.receiveBuffer.append(data)
                self.drainFrames()
            }
            if let error {
                self.writeLog("RemoteClient receive error: \(error.localizedDescription)")
                self.stateHandler?(.failed(error.localizedDescription))
                self.cancel()
                return
            }
            if isComplete {
                self.writeLog("RemoteClient receive: isComplete")
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
    ///
    /// v2.3.4 修复：把所有 sub-data 强制转为 [UInt8] 数组。
    ///
    /// 之前 v2.2.6 / v2.3.3 都没真正解决 use-after-free：
    ///   - v2.2.6: typeBytes = receiveBuffer.prefix(4) 是 SubSequence，引用 receiveBuffer
    ///   - v2.3.3: typeBytes = receiveBuffer.subdata(in: 0..<4) 在 iOS 26 的 Swift
    ///              实现中**仍 share backing buffer**（copy-on-write 优化下 subdata
    ///              不一定复制）
    ///
    /// 当 receiveBuffer.removeFirst(totalNeeded) 触发 buffer 重新分配后，
    /// typeBytes 仍指向旧 backing（已被 free）→ 访问 typeBytes[1] 触发
    /// Data._Representation.subscript.getter SIGTRAP。
    ///
    /// 真正安全的做法：把 Data 强制转换为 [UInt8]（Array）。
    /// Array 是 Swift 中的值类型，Array(_:) 构造器**总是**复制底层字节。
    /// 复制后的 [UInt8] 不可能引用任何 backing buffer，use-after-free 不可能发生。
    private func drainFrames() {
        while receiveBuffer.count >= 8 {
            // 关键：Array(_:) 构造器强制复制为值类型，100% 安全
            let header: [UInt8] = Array(receiveBuffer.prefix(8))
            let typeInt = UInt32(header[0]) |
                          (UInt32(header[1]) << 8) |
                          (UInt32(header[2]) << 16) |
                          (UInt32(header[3]) << 24)
            let frameLen = UInt32(header[4]) |
                           (UInt32(header[5]) << 8) |
                           (UInt32(header[6]) << 16) |
                           (UInt32(header[7]) << 24)

            // 防御：避免恶意 / 异常长度撑爆内存
            if frameLen > 8 * 1024 * 1024 {
                stateHandler?(.failed("frame too large: \(frameLen)"))
                cancel()
                return
            }

            let totalNeeded = 8 + Int(frameLen)
            if receiveBuffer.count < totalNeeded { break }

            // flags 从 header 数组取，header 是 [UInt8]，访问绝对安全
            let flags: UInt8 = header[1]

            // payload 同样强制 Array 复制
            let payloadBytes: [UInt8]
            if frameLen == 0 {
                payloadBytes = []
            } else {
                payloadBytes = Array(receiveBuffer.prefix(totalNeeded).suffix(Int(frameLen)))
            }
            receiveBuffer.removeFirst(totalNeeded)

            // typeBytes 字段用 [UInt8] 强制 Data 构造器（Data 构造器也是复制）
            let frame = IncomingFrame(
                typeBytes: Data([header[0], header[1], header[2], header[3]]),
                type: typeInt,
                flags: flags,
                payload: Data(payloadBytes)
            )
            frameHandler?(frame)
        }
    }
}
