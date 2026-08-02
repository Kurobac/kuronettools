import Dispatch
import dnssd
import Foundation
import NetToolCore

struct SystemDNSQueryConfiguration: Sendable {
    let name: String
    let type: DNSRecordType
    let timeoutSeconds: Double

    func validated() throws -> SystemDNSQueryConfiguration {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty else {
            throw DNSConfigurationError.emptyName
        }
        guard timeoutSeconds.isFinite,
              (0.1 ... 30).contains(timeoutSeconds) else {
            throw DNSConfigurationError.invalidTimeout
        }

        _ = try DNSMessageCodec.makeQuery(
            identifier: 0,
            name: trimmedName,
            type: type,
            recursionDesired: true
        )

        return SystemDNSQueryConfiguration(
            name: trimmedName,
            type: type,
            timeoutSeconds: timeoutSeconds
        )
    }
}

struct SystemDNSQueryResult: Sendable {
    let name: String
    let type: DNSRecordType
    let records: [DNSResourceRecord]
    let roundTripTimeMilliseconds: Double
}

enum SystemDNSClientError: Error, LocalizedError, Sendable {
    case start(Int32)
    case schedule(Int32)
    case response(Int32)
    case timeout(seconds: Double)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .start(let code):
            "无法启动系统 DNS 查询（错误 \(code)）。"
        case .schedule(let code):
            "无法调度系统 DNS 查询（错误 \(code)）。"
        case .response(let code):
            if code == DNSServiceErrorType(kDNSServiceErr_NoSuchName)
                || code == DNSServiceErrorType(kDNSServiceErr_NoSuchRecord) {
                "系统解析器未返回匹配记录。"
            } else {
                "系统 DNS 查询失败（错误 \(code)）。"
            }
        case .timeout(let seconds):
            "系统 DNS 查询在 \(seconds) 秒后超时。"
        case .emptyResponse:
            "系统解析器未返回匹配记录。"
        }
    }
}

struct SystemDNSQueryClient: Sendable {
    func query(
        configuration: SystemDNSQueryConfiguration
    ) async throws -> SystemDNSQueryResult {
        try Task.checkCancellation()
        let configuration = try configuration.validated()
        let operation = SystemDNSQueryOperation(
            configuration: configuration
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.begin(continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class SystemDNSQueryOperation: @unchecked Sendable {
    private enum State: Equatable {
        case idle
        case cancelledBeforeStart
        case running
        case finished
    }

    private let configuration: SystemDNSQueryConfiguration
    private let queue = DispatchQueue(
        label: "dev.kurobac.NetTool.system-dns"
    )
    private let startedAt = ContinuousClock.now

    private var state = State.idle
    private var continuation: CheckedContinuation<
        SystemDNSQueryResult,
        Error
    >?
    private var serviceRef: DNSServiceRef?
    private var timeoutWorkItem: DispatchWorkItem?
    private var records: [DNSResourceRecord] = []
    private var lifetime: SystemDNSQueryOperation?

    init(configuration: SystemDNSQueryConfiguration) {
        self.configuration = configuration
    }

    func begin(
        continuation: CheckedContinuation<SystemDNSQueryResult, Error>
    ) {
        queue.async { [self] in
            switch state {
            case .idle:
                self.continuation = continuation
                start()
            case .cancelledBeforeStart:
                state = .finished
                continuation.resume(throwing: CancellationError())
            case .running, .finished:
                preconditionFailure("System DNS operation started twice")
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            switch state {
            case .idle:
                state = .cancelledBeforeStart
            case .running:
                finish(.failure(CancellationError()))
            case .cancelledBeforeStart, .finished:
                break
            }
        }
    }

    private func start() {
        state = .running
        lifetime = self

        var newServiceRef: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let queryFlags = DNSServiceFlags(
            kDNSServiceFlagsReturnIntermediates
        )
        let error = DNSServiceQueryRecord(
            &newServiceRef,
            queryFlags,
            0,
            configuration.name,
            configuration.type.rawValue,
            UInt16(kDNSServiceClass_IN),
            systemDNSQueryReply,
            context
        )

        guard error == kDNSServiceErr_NoError,
              let newServiceRef else {
            finish(.failure(SystemDNSClientError.start(error)))
            return
        }

        serviceRef = newServiceRef
        let scheduleError = DNSServiceSetDispatchQueue(
            newServiceRef,
            queue
        )
        guard scheduleError == kDNSServiceErr_NoError else {
            finish(
                .failure(SystemDNSClientError.schedule(scheduleError))
            )
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [self] in
            finish(
                .failure(
                    SystemDNSClientError.timeout(
                        seconds: configuration.timeoutSeconds
                    )
                )
            )
        }
        self.timeoutWorkItem = timeoutWorkItem
        queue.asyncAfter(
            deadline: .now() + configuration.timeoutSeconds,
            execute: timeoutWorkItem
        )
    }

    fileprivate func receive(
        flags: DNSServiceFlags,
        errorCode: DNSServiceErrorType,
        fullname: UnsafePointer<CChar>?,
        typeCode: UInt16,
        classCode: UInt16,
        dataLength: UInt16,
        dataPointer: UnsafeRawPointer?,
        timeToLive: UInt32
    ) {
        guard state == .running else {
            return
        }
        guard errorCode == kDNSServiceErr_NoError else {
            finish(.failure(SystemDNSClientError.response(errorCode)))
            return
        }

        let addFlag = DNSServiceFlags(kDNSServiceFlagsAdd)
        let isAddedRecord = flags & addFlag != 0
        if isAddedRecord,
           let fullname,
           let dataPointer {
            do {
                let data = Array(
                    UnsafeBufferPointer(
                        start: dataPointer.assumingMemoryBound(
                            to: UInt8.self
                        ),
                        count: Int(dataLength)
                    )
                )
                let record = DNSResourceRecord(
                    name: String(cString: fullname),
                    typeCode: typeCode,
                    classCode: classCode,
                    timeToLive: timeToLive,
                    data: try DNSMessageCodec.parseRecordData(
                        typeCode: typeCode,
                        bytes: data
                    )
                )
                if !records.contains(record) {
                    records.append(record)
                }
            } catch {
                finish(.failure(error))
                return
            }
        }

        let moreComingFlag = DNSServiceFlags(kDNSServiceFlagsMoreComing)
        guard flags & moreComingFlag == 0 else {
            return
        }
        if !isAddedRecord,
           !records.contains(where: {
               $0.typeCode == configuration.type.rawValue
           }) {
            finish(.failure(SystemDNSClientError.emptyResponse))
            return
        }
        guard records.contains(where: {
            $0.typeCode == configuration.type.rawValue
        }) else {
            return
        }

        let elapsed = startedAt.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        finish(
            .success(
                SystemDNSQueryResult(
                    name: configuration.name,
                    type: configuration.type,
                    records: records,
                    roundTripTimeMilliseconds: milliseconds
                )
            )
        )
    }

    private func finish(
        _ result: Result<SystemDNSQueryResult, Error>
    ) {
        guard state == .running,
              let continuation else {
            return
        }

        state = .finished
        self.continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let serviceRef {
            self.serviceRef = nil
            DNSServiceRefDeallocate(serviceRef)
        }
        lifetime = nil
        continuation.resume(with: result)
    }
}

private func systemDNSQueryReply(
    _ serviceRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ typeCode: UInt16,
    _ classCode: UInt16,
    _ dataLength: UInt16,
    _ dataPointer: UnsafeRawPointer?,
    _ timeToLive: UInt32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else {
        return
    }

    let operation = Unmanaged<SystemDNSQueryOperation>
        .fromOpaque(context)
        .takeUnretainedValue()
    operation.receive(
        flags: flags,
        errorCode: errorCode,
        fullname: fullname,
        typeCode: typeCode,
        classCode: classCode,
        dataLength: dataLength,
        dataPointer: dataPointer,
        timeToLive: timeToLive
    )
}
