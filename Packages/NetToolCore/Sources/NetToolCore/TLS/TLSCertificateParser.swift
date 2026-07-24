import CryptoKit
import Foundation
import X509

public enum TLSCertificateParser {
    public static func parse(
        derCertificates: [Data]
    ) throws -> [TLSCertificateInfo] {
        try derCertificates.enumerated().map { index, data in
            do {
                let certificate = try Certificate(
                    derEncoded: Array(data)
                )
                let alternativeNames = try certificate.extensions
                    .subjectAlternativeNames?
                    .map(formatAlternativeName) ?? []

                return TLSCertificateInfo(
                    index: index,
                    subject: certificate.subject.description,
                    issuer: certificate.issuer.description,
                    notValidBefore: certificate.notValidBefore,
                    notValidAfter: certificate.notValidAfter,
                    serialNumber: hex(
                        certificate.serialNumber.bytes,
                        separator: ":"
                    ),
                    subjectAlternativeNames: alternativeNames,
                    publicKey: certificate.publicKey.description,
                    signatureAlgorithm: certificate
                        .signatureAlgorithm
                        .description
                        .replacingOccurrences(
                            of: "SignatureAlgorithm.",
                            with: ""
                        ),
                    sha256Fingerprint: hex(
                        SHA256.hash(data: data),
                        separator: ":"
                    )
                )
            } catch {
                throw TLSCertificateParserError.invalidCertificate(
                    index: index,
                    message: error.localizedDescription
                )
            }
        }
    }

    private static func formatAlternativeName(
        _ name: GeneralName
    ) -> String {
        switch name {
        case .dnsName(let value):
            "DNS:\(value)"
        case .ipAddress(let value):
            "IP:\(formatIPAddress(Array(value.bytes)))"
        case .rfc822Name(let value):
            "Email:\(value)"
        case .uniformResourceIdentifier(let value):
            "URI:\(value)"
        case .directoryName(let value):
            "Directory:\(value.description)"
        case .registeredID(let value):
            "RID:\(value)"
        case .otherName, .x400Address, .ediPartyName:
            String(describing: name)
        }
    }

    private static func formatIPAddress(
        _ bytes: [UInt8]
    ) -> String {
        switch bytes.count {
        case 4:
            bytes.map(String.init).joined(separator: ".")
        case 16:
            stride(from: 0, to: 16, by: 2).map {
                String(
                    format: "%02X%02X",
                    bytes[$0],
                    bytes[$0 + 1]
                )
            }.joined(separator: ":")
        default:
            hex(bytes, separator: ":")
        }
    }

    private static func hex<Bytes: Sequence>(
        _ bytes: Bytes,
        separator: String
    ) -> String where Bytes.Element == UInt8 {
        bytes.map {
            String(format: "%02X", $0)
        }.joined(separator: separator)
    }
}

public enum TLSCertificateParserError:
    Error,
    Equatable,
    LocalizedError
{
    case invalidCertificate(index: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCertificate(let index, let message):
            "无法解析证书链中的第 \(index + 1) 张证书：\(message)"
        }
    }
}
