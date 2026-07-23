public enum ICMPAddressFamily: Equatable, Sendable {
    case ipv4
    case ipv6
}

public struct ICMPEchoHeader: Equatable, Sendable {
    public let type: UInt8
    public let code: UInt8
    public let checksum: UInt16
    public let identifier: UInt16
    public let sequence: UInt16

    public init(
        type: UInt8,
        code: UInt8,
        checksum: UInt16,
        identifier: UInt16,
        sequence: UInt16
    ) {
        self.type = type
        self.code = code
        self.checksum = checksum
        self.identifier = identifier
        self.sequence = sequence
    }
}

public enum ICMPPacketCodec {
    public static let headerLength = 8

    public static func makeEchoRequest(
        family: ICMPAddressFamily,
        identifier: UInt16,
        sequence: UInt16,
        payloadSize: Int
    ) -> [UInt8] {
        precondition(payloadSize >= 0)

        var packet = [UInt8](
            repeating: 0,
            count: headerLength + payloadSize
        )

        packet[0] = echoRequestType(for: family)
        write(identifier, to: &packet, at: 4)
        write(sequence, to: &packet, at: 6)

        if payloadSize > 0 {
            for index in 0 ..< payloadSize {
                packet[headerLength + index] = UInt8(0x21 + (index % 94))
            }
        }

        if family == .ipv4 {
            write(checksum(of: packet), to: &packet, at: 2)
        }

        return packet
    }

    public static func parseHeader(
        from packet: [UInt8],
        offset: Int = 0
    ) -> ICMPEchoHeader? {
        guard offset >= 0, packet.count >= offset + headerLength else {
            return nil
        }

        return ICMPEchoHeader(
            type: packet[offset],
            code: packet[offset + 1],
            checksum: readUInt16(from: packet, at: offset + 2),
            identifier: readUInt16(from: packet, at: offset + 4),
            sequence: readUInt16(from: packet, at: offset + 6)
        )
    }

    public static func isEchoReply(
        _ header: ICMPEchoHeader,
        family: ICMPAddressFamily,
        identifier: UInt16,
        sequence: UInt16
    ) -> Bool {
        header.type == echoReplyType(for: family)
            && header.code == 0
            && header.identifier == identifier
            && header.sequence == sequence
    }

    public static func checksum(of bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0

        while index + 1 < bytes.count {
            let word = UInt16(bytes[index]) << 8
                | UInt16(bytes[index + 1])
            sum += UInt32(word)
            index += 2
        }

        if index < bytes.count {
            sum += UInt32(UInt16(bytes[index]) << 8)
        }

        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }

        return ~UInt16(sum & 0xffff)
    }

    public static func echoRequestType(
        for family: ICMPAddressFamily
    ) -> UInt8 {
        switch family {
        case .ipv4:
            8
        case .ipv6:
            128
        }
    }

    public static func echoReplyType(
        for family: ICMPAddressFamily
    ) -> UInt8 {
        switch family {
        case .ipv4:
            0
        case .ipv6:
            129
        }
    }

    private static func readUInt16(
        from bytes: [UInt8],
        at offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func write(
        _ value: UInt16,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(value >> 8)
        bytes[offset + 1] = UInt8(value & 0xff)
    }
}
