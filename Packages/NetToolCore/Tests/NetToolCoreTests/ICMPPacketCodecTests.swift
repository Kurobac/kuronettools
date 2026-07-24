import Testing

@testable import NetToolCore

@Suite("ICMP packet codec")
struct ICMPPacketCodecTests {
    @Test("IPv4 request uses network byte order and valid checksum")
    func createsIPv4Request() {
        let packet = ICMPPacketCodec.makeEchoRequest(
            family: .ipv4,
            identifier: 0x1234,
            sequence: 1,
            payloadSize: 0
        )

        #expect(packet == [8, 0, 0xe5, 0xca, 0x12, 0x34, 0, 1])
        #expect(ICMPPacketCodec.checksum(of: packet) == 0)
    }

    @Test("IPv6 request leaves checksum for the kernel")
    func createsIPv6Request() {
        let packet = ICMPPacketCodec.makeEchoRequest(
            family: .ipv6,
            identifier: 0xabcd,
            sequence: 0x1020,
            payloadSize: 2
        )

        #expect(
            packet == [
                128, 0, 0, 0, 0xab, 0xcd, 0x10, 0x20, 0x21, 0x22
            ]
        )
    }

    @Test("Reply parser rejects a different sequence")
    func verifiesReplyIdentity() throws {
        let packet: [UInt8] = [
            0, 0, 0, 0, 0x12, 0x34, 0, 2
        ]
        let header = try #require(
            ICMPPacketCodec.parseHeader(from: packet)
        )

        #expect(
            ICMPPacketCodec.isEchoReply(
                header,
                family: .ipv4,
                identifier: 0x1234,
                sequence: 1
            ) == false
        )
    }

    @Test("IPv4 time exceeded matches the embedded echo request")
    func matchesIPv4TimeExceeded() {
        var packet = [UInt8](repeating: 0, count: 20)
        packet[0] = 0x45
        packet[9] = 1
        packet += [11, 0, 0, 0, 0, 0, 0, 0]

        var embeddedIPv4 = [UInt8](repeating: 0, count: 20)
        embeddedIPv4[0] = 0x45
        embeddedIPv4[9] = 1
        packet += embeddedIPv4
        packet += [8, 0, 0, 0, 0x12, 0x34, 0, 7]

        #expect(
            ICMPPacketCodec.isTimeExceededResponse(
                in: packet,
                offset: 20,
                family: .ipv4,
                identifier: 0x1234,
                sequence: 7
            )
        )
    }

    @Test("IPv6 time exceeded matches the embedded echo request")
    func matchesIPv6TimeExceeded() {
        var packet: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 0]
        var embeddedIPv6 = [UInt8](repeating: 0, count: 40)
        embeddedIPv6[0] = 0x60
        embeddedIPv6[6] = 58
        packet += embeddedIPv6
        packet += [128, 0, 0, 0, 0xab, 0xcd, 0, 9]

        #expect(
            ICMPPacketCodec.isTimeExceededResponse(
                in: packet,
                offset: 0,
                family: .ipv6,
                identifier: 0xabcd,
                sequence: 9
            )
        )
    }

    @Test("Time exceeded rejects a different embedded sequence")
    func rejectsDifferentEmbeddedSequence() {
        var packet: [UInt8] = [11, 0, 0, 0, 0, 0, 0, 0]
        var embeddedIPv4 = [UInt8](repeating: 0, count: 20)
        embeddedIPv4[0] = 0x45
        embeddedIPv4[9] = 1
        packet += embeddedIPv4
        packet += [8, 0, 0, 0, 0x12, 0x34, 0, 2]

        #expect(
            ICMPPacketCodec.isTimeExceededResponse(
                in: packet,
                offset: 0,
                family: .ipv4,
                identifier: 0x1234,
                sequence: 1
            ) == false
        )
    }
}
