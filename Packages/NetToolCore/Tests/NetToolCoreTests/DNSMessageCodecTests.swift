import Testing

@testable import NetToolCore

@Suite("DNS message codec")
struct DNSMessageCodecTests {
    @Test("Query encoder produces RFC 1035 wire format")
    func encodesQuery() throws {
        let query = try DNSMessageCodec.makeQuery(
            identifier: 0x1234,
            name: "example.com",
            type: .a,
            recursionDesired: true
        )

        #expect(
            query == [
                0x12, 0x34, 0x01, 0x00,
                0x00, 0x01, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x07, 0x65, 0x78, 0x61,
                0x6d, 0x70, 0x6c, 0x65,
                0x03, 0x63, 0x6f, 0x6d,
                0x00, 0x00, 0x01, 0x00,
                0x01
            ]
        )
    }

    @Test("Parser reads flags and a compressed A response")
    func parsesAResponse() throws {
        let response = try DNSMessageCodec.parse(
            responseMessage(
                typeCode: DNSRecordType.a.rawValue,
                timeToLive: 300,
                recordData: [93, 184, 216, 34]
            )
        )

        #expect(response.identifier == 0x1234)
        #expect(response.flags.isResponse)
        #expect(response.flags.recursionDesired)
        #expect(response.flags.recursionAvailable)
        #expect(response.flags.responseCodeName == "NOERROR")
        #expect(response.questions.first?.name == "example.com.")
        #expect(response.answers.first?.timeToLive == 300)
        #expect(response.answers.first?.data == .a("93.184.216.34"))
    }

    @Test("Parser handles supported resource record data")
    func parsesSupportedRecordData() throws {
        let cases: [(UInt16, [UInt8], DNSRecordData)] = [
            (
                DNSRecordType.aaaa.rawValue,
                [
                    0x20, 0x01, 0x0d, 0xb8,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 1
                ],
                .aaaa("2001:db8::1")
            ),
            (
                DNSRecordType.cname.rawValue,
                [0xc0, 0x0c],
                .domainName("example.com.")
            ),
            (
                DNSRecordType.mx.rawValue,
                [0, 10, 0x04, 0x6d, 0x61, 0x69, 0x6c, 0xc0, 0x0c],
                .mx(preference: 10, exchange: "mail.example.com.")
            ),
            (
                DNSRecordType.txt.rawValue,
                [3, 0x66, 0x6f, 0x6f, 3, 0x62, 0x61, 0x72],
                .txt(["foo", "bar"])
            ),
            (
                DNSRecordType.soa.rawValue,
                [
                    0x02, 0x6e, 0x73, 0xc0, 0x0c,
                    0x0a, 0x68, 0x6f, 0x73, 0x74, 0x6d,
                    0x61, 0x73, 0x74, 0x65, 0x72, 0xc0, 0x0c,
                    0, 0, 0, 1,
                    0, 0, 0, 2,
                    0, 0, 0, 3,
                    0, 0, 0, 4,
                    0, 0, 0, 5
                ],
                .soa(
                    primaryNameServer: "ns.example.com.",
                    responsibleMailbox: "hostmaster.example.com.",
                    serial: 1,
                    refresh: 2,
                    retry: 3,
                    expire: 4,
                    minimum: 5
                )
            ),
            (
                DNSRecordType.srv.rawValue,
                [
                    0, 1, 0, 2, 0x01, 0xbb,
                    0x03, 0x73, 0x76, 0x63, 0xc0, 0x0c
                ],
                .srv(
                    priority: 1,
                    weight: 2,
                    port: 443,
                    target: "svc.example.com."
                )
            ),
            (
                DNSRecordType.caa.rawValue,
                [
                    0, 5,
                    0x69, 0x73, 0x73, 0x75, 0x65,
                    0x6c, 0x65, 0x74, 0x73, 0x65, 0x6e, 0x63,
                    0x72, 0x79, 0x70, 0x74, 0x2e, 0x6f, 0x72, 0x67
                ],
                .caa(flags: 0, tag: "issue", value: "letsencrypt.org")
            )
        ]

        for (typeCode, recordData, expected) in cases {
            let response = try DNSMessageCodec.parse(
                responseMessage(
                    typeCode: typeCode,
                    timeToLive: 60,
                    recordData: recordData
                )
            )

            #expect(response.answers.first?.data == expected)
        }
    }

    @Test("Unknown resource records preserve their raw bytes")
    func preservesUnknownRecordData() throws {
        let response = try DNSMessageCodec.parse(
            responseMessage(
                typeCode: 65,
                timeToLive: 60,
                recordData: [1, 2, 3, 4]
            )
        )

        #expect(response.answers.first?.typeName == "TYPE65")
        #expect(response.answers.first?.data == .raw([1, 2, 3, 4]))
    }

    @Test("Compression loops are rejected")
    func rejectsCompressionLoop() {
        let message: [UInt8] = [
            0x12, 0x34, 0x81, 0x80,
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0xc0, 0x0c,
            0x00, 0x01, 0x00, 0x01
        ]

        #expect(throws: DNSCodecError.compressionLoop) {
            try DNSMessageCodec.parse(message)
        }
    }

    @Test("Truncated resource data is rejected")
    func rejectsTruncatedRecord() {
        var message = responseMessage(
            typeCode: DNSRecordType.a.rawValue,
            timeToLive: 60,
            recordData: [1, 2, 3, 4]
        )
        message.removeLast()

        #expect(throws: DNSCodecError.truncatedMessage) {
            try DNSMessageCodec.parse(message)
        }
    }

    @Test("Non-ASCII names are rejected until IDNA support is added")
    func rejectsNonASCIIName() {
        #expect(throws: DNSCodecError.invalidDomainName) {
            try DNSMessageCodec.makeQuery(
                identifier: 1,
                name: "例子.测试",
                type: .a,
                recursionDesired: true
            )
        }
    }

    private func responseMessage(
        typeCode: UInt16,
        timeToLive: UInt32,
        recordData: [UInt8]
    ) -> [UInt8] {
        var bytes: [UInt8] = [
            0x12, 0x34, 0x81, 0x80,
            0x00, 0x01, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x07, 0x65, 0x78, 0x61,
            0x6d, 0x70, 0x6c, 0x65,
            0x03, 0x63, 0x6f, 0x6d,
            0x00
        ]
        append(typeCode, to: &bytes)
        append(UInt16(1), to: &bytes)

        bytes.append(contentsOf: [0xc0, 0x0c])
        append(typeCode, to: &bytes)
        append(UInt16(1), to: &bytes)
        append(timeToLive, to: &bytes)
        append(UInt16(recordData.count), to: &bytes)
        bytes.append(contentsOf: recordData)
        return bytes
    }

    private func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }

    private func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }
}
