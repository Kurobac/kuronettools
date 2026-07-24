import Testing

@testable import NetToolCore

@Suite("DNS stream codec")
struct DNSStreamCodecTests {
    @Test("Frames and decodes one TCP DNS message")
    func framesMessage() throws {
        let message: [UInt8] = [0x12, 0x34, 0x01, 0x00]
        let frame = try DNSStreamCodec.frame(message)

        #expect(frame == [0x00, 0x04, 0x12, 0x34, 0x01, 0x00])
        #expect(try DNSStreamCodec.decodeSingleFrame(frame) == message)
    }

    @Test("Partial frames wait for more bytes")
    func waitsForCompleteFrame() throws {
        #expect(
            try DNSStreamCodec.decodeSingleFrame([0x00]) == nil
        )
        #expect(
            try DNSStreamCodec.decodeSingleFrame(
                [0x00, 0x04, 0x12, 0x34]
            ) == nil
        )
    }

    @Test("Empty and trailing stream data are rejected")
    func rejectsInvalidFrames() {
        #expect(throws: DNSStreamCodecError.emptyMessage) {
            try DNSStreamCodec.frame([])
        }
        #expect(throws: DNSStreamCodecError.emptyMessage) {
            try DNSStreamCodec.decodeSingleFrame([0x00, 0x00])
        }
        #expect(throws: DNSStreamCodecError.trailingData) {
            try DNSStreamCodec.decodeSingleFrame(
                [0x00, 0x01, 0xaa, 0xbb]
            )
        }
    }
}
