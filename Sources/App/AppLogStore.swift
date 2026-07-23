import Foundation
import Observation

enum AppLogLevel: String, Equatable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct AppLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: AppLogLevel
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: AppLogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

@MainActor
@Observable
final class AppLogStore {
    private(set) var entries: [AppLogEntry] = []

    @ObservationIgnored
    private var didRecordLaunch = false

    func recordLaunchIfNeeded() {
        guard !didRecordLaunch else {
            return
        }

        didRecordLaunch = true

        let metadata = AppMetadata.current
        append(
            level: .info,
            message: "\(metadata.name) \(metadata.versionDescription) 启动"
        )
        append(
            level: .debug,
            message: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    func append(level: AppLogLevel, message: String) {
        entries.append(
            AppLogEntry(
                level: level,
                message: message
            )
        )
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        let formatter = ISO8601DateFormatter()

        return entries
            .map { entry in
                let timestamp = formatter.string(from: entry.timestamp)
                return "[\(timestamp)] [\(entry.level.rawValue)] \(entry.message)"
            }
            .joined(separator: "\n")
    }
}
