import Foundation

struct AppMetadata: Equatable, Sendable {
    let name: String
    let version: String
    let build: String
    let bundleIdentifier: String
    let minimumSystemVersion: String

    var versionDescription: String {
        "\(version) (\(build))"
    }

    @MainActor
    static var current: AppMetadata {
        let info = Bundle.main.infoDictionary ?? [:]

        return AppMetadata(
            name: info["CFBundleDisplayName"] as? String ?? "NetTool",
            version: info["CFBundleShortVersionString"] as? String ?? "0.1.0",
            build: info["CFBundleVersion"] as? String ?? "1",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.kurobac.NetTool",
            minimumSystemVersion: info["MinimumOSVersion"] as? String ?? "26.0"
        )
    }
}
