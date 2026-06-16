//
//  CommandBuilder.swift
//  RemotePlay
//
//  12 字节上行控制指令构造器。
//  协议与 Android 端 MainActivity 严格保持一致：
//
//  字节布局：
//    [0]   cmdType   0x01=触摸事件   0x02=按钮事件
//    [1]   action    0x01=按下       0x00=抬起
//    [2-3] reserved  0x00
//    [4-7] argA      小端 int：
//                    - 触摸事件：x 坐标
//                    - 按钮事件：按钮编码（run=0x08, single=0x09, auto=0x30,
//                                         half=0x31, home=0x61, up=0x51）
//    [8-11] argB     小端 int：
//                    - 触摸事件：y 坐标
//                    - 按钮事件：0x01=按下 / 0x00=抬起
//

import Foundation

enum CommandBuilder {

    /// 命令类型
    private static let kCmdTouch: UInt8 = 0x01
    private static let kCmdButton: UInt8 = 0x02

    /// 动作
    private static let kActionDown: UInt8 = 0x01
    private static let kActionUp: UInt8 = 0x00

    /// 构造触摸指令。
    /// - Parameters:
    ///   - x: 已换算到视频原始尺寸的 X 坐标
    ///   - y: 已换算到视频原始尺寸的 Y 坐标
    ///   - pressDown: true=按下 / false=抬起
    static func touch(x: Int, y: Int, pressDown: Bool) -> Data {
        var data = Data(count: 12)
        data[0] = kCmdTouch
        data[1] = pressDown ? kActionDown : kActionUp
        data[2] = 0
        data[3] = 0
        writeInt32(x, into: &data, at: 4)
        writeInt32(y, into: &data, at: 8)
        return data
    }

    /// 构造按钮指令。
    /// - Parameters:
    ///   - code: 按钮编码（与 Android 端 byte[4] 一致）
    ///   - pressDown: true=按下 / false=抬起
    static func button(code: UInt8, pressDown: Bool) -> Data {
        var data = Data(count: 12)
        data[0] = kCmdButton
        data[1] = 0x00
        data[2] = 0x00
        data[3] = 0x00
        data[4] = 0x00
        data[5] = 0x00
        data[6] = 0x00
        data[7] = code
        data[8] = 0x00
        data[9] = 0x00
        data[10] = 0x00
        data[11] = pressDown ? 0x01 : 0x00
        return data
    }

    /// 小端 int32 写入 Data。
    private static func writeInt32(_ value: Int, into data: inout Data, at offset: Int) {
        let v = UInt32(bitPattern: Int32(value))
        data[offset]     = UInt8( v         & 0xFF)
        data[offset + 1] = UInt8((v >> 8)  & 0xFF)
        data[offset + 2] = UInt8((v >> 16) & 0xFF)
        data[offset + 3] = UInt8((v >> 24) & 0xFF)
    }
}

/// 按钮枚举与编码，与 Android 端 onTouchButtonListener 中的 case 一一对应。
enum RemoteButtonCode: UInt8 {
    case run     = 0x08
    case single  = 0x09
    case auto    = 0x30
    case half    = 0x31
    case home    = 0x61
    case up      = 0x51
    case down    = 0x33   // 兼容 Android 端 down 按钮的 12 字节协议占位（实际为组合 clickPoint）
}
