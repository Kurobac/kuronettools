import Foundation

public enum DNSStreamCodecError: Error, Equatable, LocalizedError {
    case emptyMessage
    case messageTooLarge
    case trailingData

    public var errorDescription: String? {
        switch self {
        case .emptyMessage:
            "TCP DNS 帧声明了空报文。"
        case .messageTooLarge:
            "TCP DNS 报文不能超过 65535 字节。"
        case .trailingData:
            "TCP DNS 响应在单个帧后包含额外数据。"
        }
    }
}

public enum DNSStreamCodec {
    public static func frame(_ message: [UInt8]) throws -> [UInt8] {
        guard !message.isEmpty else {
            throw DNSStreamCodecError.emptyMessage
        }
        guard message.count <= Int(UInt16.max) else {
            throw DNSStreamCodecError.messageTooLarge
        }

        let length = UInt16(message.count)
        return [
            UInt8(length >> 8),
            UInt8(length & 0xff)
        ] + message
    }

    public static func decodeSingleFrame(
        _ bytes: [UInt8]
    ) throws -> [UInt8]? {
        guard bytes.count >= 2 else {
            return nil
        }

        let length = Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        guard length > 0 else {
            throw DNSStreamCodecError.emptyMessage
        }

        let frameLength = length + 2
        guard bytes.count <= frameLength else {
            throw DNSStreamCodecError.trailingData
        }
        guard bytes.count == frameLength else {
            return nil
        }

        return Array(bytes.dropFirst(2))
    }
}
