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
}
