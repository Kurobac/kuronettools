import Foundation

public enum DNSCodecError: Error, Equatable, LocalizedError {
    case invalidDomainName
    case labelTooLong
    case nameTooLong
    case messageTooShort
    case truncatedMessage
    case excessiveRecordCount
    case invalidLabelEncoding
    case invalidCompressionPointer
    case compressionLoop
    case invalidRecordData(typeCode: UInt16)
    case trailingData

    public var errorDescription: String? {
        switch self {
        case .invalidDomainName:
            "域名格式无效；当前版本要求使用 ASCII 域名。"
        case .labelTooLong:
            "域名中的单个标签不能超过 63 字节。"
        case .nameTooLong:
            "编码后的域名不能超过 255 字节。"
        case .messageTooShort:
            "DNS 响应短于 12 字节头部。"
        case .truncatedMessage:
            "DNS 响应在字段结束前被截断。"
        case .excessiveRecordCount:
            "DNS 响应声明了异常多的记录。"
        case .invalidLabelEncoding:
            "DNS 名称包含无效的标签编码。"
        case .invalidCompressionPointer:
            "DNS 名称压缩指针超出报文范围。"
        case .compressionLoop:
            "DNS 名称压缩指针形成循环。"
        case .invalidRecordData(let typeCode):
            "TYPE\(typeCode) 记录的数据格式无效。"
        case .trailingData:
            "DNS 响应包含未声明的尾随数据。"
        }
    }
}

public enum DNSMessageCodec {
    public static func makeQuery(
        identifier: UInt16,
        name: String,
        type: DNSRecordType,
        recursionDesired: Bool
    ) throws -> [UInt8] {
        let encodedName = try encodeName(name)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(12 + encodedName.count + 4)

        append(identifier, to: &bytes)
        append(recursionDesired ? 0x0100 : 0x0000, to: &bytes)
        append(1, to: &bytes)
        append(0, to: &bytes)
        append(0, to: &bytes)
        append(0, to: &bytes)
        bytes.append(contentsOf: encodedName)
        append(type.rawValue, to: &bytes)
        append(1, to: &bytes)

        return bytes
    }

    public static func parse(_ bytes: [UInt8]) throws -> DNSMessage {
        guard bytes.count >= 12 else {
            throw DNSCodecError.messageTooShort
        }

        var reader = DNSReader(bytes: bytes)
        let identifier = try reader.readUInt16()
        let flags = DNSMessageFlags(rawValue: try reader.readUInt16())
        let questionCount = Int(try reader.readUInt16())
        let answerCount = Int(try reader.readUInt16())
        let authorityCount = Int(try reader.readUInt16())
        let additionalCount = Int(try reader.readUInt16())

        let resourceRecordCount =
            answerCount + authorityCount + additionalCount
        guard questionCount <= 64, resourceRecordCount <= 4_096 else {
            throw DNSCodecError.excessiveRecordCount
        }

        var questions: [DNSQuestion] = []
        questions.reserveCapacity(questionCount)
        for _ in 0 ..< questionCount {
            questions.append(try reader.readQuestion())
        }

        let answers = try reader.readRecords(count: answerCount)
        let authorities = try reader.readRecords(count: authorityCount)
        let additionals = try reader.readRecords(count: additionalCount)

        guard reader.isAtEnd else {
            throw DNSCodecError.trailingData
        }

        return DNSMessage(
            identifier: identifier,
            flags: flags,
            questions: questions,
            answers: answers,
            authorities: authorities,
            additionals: additionals
        )
    }

    public static func hexadecimalString(for bytes: [UInt8]) -> String {
        bytes.enumerated().map { index, byte in
            let value = String(format: "%02x", Int(byte))
            return (index + 1).isMultiple(of: 16)
                ? value + "\n"
                : value + " "
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension DNSMessageCodec {
    static func encodeName(_ name: String) throws -> [UInt8] {
        if name == "." {
            return [0]
        }

        let normalized = name.hasSuffix(".")
            ? String(name.dropLast())
            : name
        guard !normalized.isEmpty else {
            throw DNSCodecError.invalidDomainName
        }

        let labels = normalized.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        var bytes: [UInt8] = []

        for label in labels {
            let labelBytes = Array(label.utf8)
            guard !labelBytes.isEmpty,
                  labelBytes.allSatisfy({ 0x21 ... 0x7e ~= $0 }) else {
                throw DNSCodecError.invalidDomainName
            }
            guard labelBytes.count <= 63 else {
                throw DNSCodecError.labelTooLong
            }

            bytes.append(UInt8(labelBytes.count))
            bytes.append(contentsOf: labelBytes)
        }

        bytes.append(0)
        guard bytes.count <= 255 else {
            throw DNSCodecError.nameTooLong
        }

        return bytes
    }

    static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }
}

private struct DNSReader {
    let bytes: [UInt8]
    private(set) var index = 0

    var isAtEnd: Bool {
        index == bytes.count
    }

    mutating func readQuestion() throws -> DNSQuestion {
        let name = try readName()
        let typeCode = try readUInt16()
        let classCode = try readUInt16()

        return DNSQuestion(
            name: name,
            typeCode: typeCode,
            classCode: classCode
        )
    }

    mutating func readRecords(
        count: Int
    ) throws -> [DNSResourceRecord] {
        var records: [DNSResourceRecord] = []
        records.reserveCapacity(count)

        for _ in 0 ..< count {
            records.append(try readRecord())
        }

        return records
    }

    mutating func readUInt16() throws -> UInt16 {
        guard index + 2 <= bytes.count else {
            throw DNSCodecError.truncatedMessage
        }

        let value = UInt16(bytes[index]) << 8
            | UInt16(bytes[index + 1])
        index += 2
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw DNSCodecError.truncatedMessage
        }

        let value = UInt32(bytes[index]) << 24
            | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8
            | UInt32(bytes[index + 3])
        index += 4
        return value
    }

    mutating func readName() throws -> String {
        var cursor = index
        let name = try decodeName(cursor: &cursor)
        index = cursor
        return name
    }
}

private extension DNSReader {
    mutating func readRecord() throws -> DNSResourceRecord {
        let name = try readName()
        let typeCode = try readUInt16()
        let classCode = try readUInt16()
        let timeToLive = try readUInt32()
        let dataLength = Int(try readUInt16())
        let dataStart = index
        let dataEnd = dataStart + dataLength

        guard dataEnd <= bytes.count else {
            throw DNSCodecError.truncatedMessage
        }

        let data = try parseRecordData(
            typeCode: typeCode,
            start: dataStart,
            end: dataEnd
        )
        index = dataEnd

        return DNSResourceRecord(
            name: name,
            typeCode: typeCode,
            classCode: classCode,
            timeToLive: timeToLive,
            data: data
        )
    }

    func parseRecordData(
        typeCode: UInt16,
        start: Int,
        end: Int
    ) throws -> DNSRecordData {
        guard let recordType = DNSRecordType(rawValue: typeCode) else {
            return .raw(Array(bytes[start ..< end]))
        }

        switch recordType {
        case .a:
            guard end - start == 4 else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }
            return .a(
                bytes[start ..< end].map {
                    String($0)
                }.joined(separator: ".")
            )
        case .aaaa:
            guard end - start == 16 else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }
            return .aaaa(ipv6String(from: start))
        case .ns, .cname, .ptr:
            var cursor = start
            let name = try decodeName(cursor: &cursor)
            try requireRecordEnd(
                cursor,
                expectedEnd: end,
                typeCode: typeCode
            )
            return .domainName(name)
        case .mx:
            guard start + 2 <= end else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }
            let preference = try uint16(at: start, limit: end)
            var cursor = start + 2
            let exchange = try decodeName(cursor: &cursor)
            try requireRecordEnd(
                cursor,
                expectedEnd: end,
                typeCode: typeCode
            )
            return .mx(
                preference: preference,
                exchange: exchange
            )
        case .txt:
            var cursor = start
            var strings: [String] = []

            while cursor < end {
                let length = Int(bytes[cursor])
                cursor += 1
                guard cursor + length <= end else {
                    throw DNSCodecError.invalidRecordData(
                        typeCode: typeCode
                    )
                }
                strings.append(
                    String(
                        decoding: bytes[cursor ..< cursor + length],
                        as: UTF8.self
                    )
                )
                cursor += length
            }

            return .txt(strings)
        case .soa:
            var cursor = start
            let primaryNameServer = try decodeName(cursor: &cursor)
            let responsibleMailbox = try decodeName(cursor: &cursor)
            guard cursor + 20 == end else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }

            return .soa(
                primaryNameServer: primaryNameServer,
                responsibleMailbox: responsibleMailbox,
                serial: try uint32(at: cursor, limit: end),
                refresh: try uint32(at: cursor + 4, limit: end),
                retry: try uint32(at: cursor + 8, limit: end),
                expire: try uint32(at: cursor + 12, limit: end),
                minimum: try uint32(at: cursor + 16, limit: end)
            )
        case .srv:
            guard start + 6 <= end else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }

            let priority = try uint16(at: start, limit: end)
            let weight = try uint16(at: start + 2, limit: end)
            let port = try uint16(at: start + 4, limit: end)
            var cursor = start + 6
            let target = try decodeName(cursor: &cursor)
            try requireRecordEnd(
                cursor,
                expectedEnd: end,
                typeCode: typeCode
            )

            return .srv(
                priority: priority,
                weight: weight,
                port: port,
                target: target
            )
        case .caa:
            guard start + 2 <= end else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }

            let flags = bytes[start]
            let tagLength = Int(bytes[start + 1])
            let tagStart = start + 2
            let valueStart = tagStart + tagLength
            guard valueStart <= end else {
                throw DNSCodecError.invalidRecordData(typeCode: typeCode)
            }

            return .caa(
                flags: flags,
                tag: String(
                    decoding: bytes[tagStart ..< valueStart],
                    as: UTF8.self
                ),
                value: String(
                    decoding: bytes[valueStart ..< end],
                    as: UTF8.self
                )
            )
        }
    }

    func decodeName(cursor: inout Int) throws -> String {
        var labels: [String] = []
        var position = cursor
        var consumedEnd: Int?
        var visitedOffsets: Set<Int> = []
        var decodedLength = 1

        while true {
            guard position < bytes.count else {
                throw DNSCodecError.truncatedMessage
            }
            guard visitedOffsets.insert(position).inserted else {
                throw DNSCodecError.compressionLoop
            }

            let lengthByte = bytes[position]
            if lengthByte & 0xc0 == 0xc0 {
                guard position + 1 < bytes.count else {
                    throw DNSCodecError.truncatedMessage
                }

                let pointer = Int(lengthByte & 0x3f) << 8
                    | Int(bytes[position + 1])
                guard pointer < bytes.count else {
                    throw DNSCodecError.invalidCompressionPointer
                }

                if consumedEnd == nil {
                    consumedEnd = position + 2
                }
                position = pointer
                continue
            }

            guard lengthByte & 0xc0 == 0 else {
                throw DNSCodecError.invalidLabelEncoding
            }

            position += 1
            if lengthByte == 0 {
                cursor = consumedEnd ?? position
                return labels.isEmpty
                    ? "."
                    : labels.joined(separator: ".") + "."
            }

            let labelLength = Int(lengthByte)
            guard labelLength <= 63,
                  position + labelLength <= bytes.count else {
                throw DNSCodecError.truncatedMessage
            }

            decodedLength += labelLength + 1
            guard decodedLength <= 255 else {
                throw DNSCodecError.nameTooLong
            }

            labels.append(
                renderLabel(bytes[position ..< position + labelLength])
            )
            position += labelLength
        }
    }

    func renderLabel(_ label: ArraySlice<UInt8>) -> String {
        label.map { byte in
            if 0x21 ... 0x7e ~= byte,
               byte != 0x2e,
               byte != 0x5c {
                return String(decoding: [byte], as: UTF8.self)
            }

            return String(format: "\\%03d", Int(byte))
        }
        .joined()
    }

    func uint16(at offset: Int, limit: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= limit else {
            throw DNSCodecError.truncatedMessage
        }

        return UInt16(bytes[offset]) << 8
            | UInt16(bytes[offset + 1])
    }

    func uint32(at offset: Int, limit: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= limit else {
            throw DNSCodecError.truncatedMessage
        }

        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    func requireRecordEnd(
        _ cursor: Int,
        expectedEnd: Int,
        typeCode: UInt16
    ) throws {
        guard cursor == expectedEnd else {
            throw DNSCodecError.invalidRecordData(typeCode: typeCode)
        }
    }

    func ipv6String(from start: Int) -> String {
        var groups: [UInt16] = []
        groups.reserveCapacity(8)

        for offset in stride(from: start, to: start + 16, by: 2) {
            groups.append(
                UInt16(bytes[offset]) << 8
                    | UInt16(bytes[offset + 1])
            )
        }

        var bestStart: Int?
        var bestLength = 0
        var cursor = 0

        while cursor < groups.count {
            guard groups[cursor] == 0 else {
                cursor += 1
                continue
            }

            let runStart = cursor
            while cursor < groups.count, groups[cursor] == 0 {
                cursor += 1
            }

            let runLength = cursor - runStart
            if runLength >= 2, runLength > bestLength {
                bestStart = runStart
                bestLength = runLength
            }
        }

        guard let bestStart else {
            return groups.map {
                String($0, radix: 16)
            }.joined(separator: ":")
        }

        let left = groups[..<bestStart].map {
            String($0, radix: 16)
        }.joined(separator: ":")
        let right = groups[(bestStart + bestLength)...].map {
            String($0, radix: 16)
        }.joined(separator: ":")

        if left.isEmpty, right.isEmpty {
            return "::"
        }
        if left.isEmpty {
            return "::" + right
        }
        if right.isEmpty {
            return left + "::"
        }
        return left + "::" + right
    }
}
