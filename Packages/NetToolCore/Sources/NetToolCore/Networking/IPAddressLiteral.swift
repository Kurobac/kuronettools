#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("IP address validation requires Darwin or Glibc.")
#endif

enum IPAddressLiteral {
    static func family(
        of address: String
    ) -> TCPAddressFamily? {
        var ipv4 = in_addr()
        if address.withCString({
            inet_pton(AF_INET, $0, &ipv4)
        }) == 1 {
            return .ipv4
        }

        let unscopedAddress = address.split(
            separator: "%",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? address
        var ipv6 = in6_addr()
        if unscopedAddress.withCString({
            inet_pton(AF_INET6, $0, &ipv6)
        }) == 1 {
            return .ipv6
        }

        return nil
    }
}
