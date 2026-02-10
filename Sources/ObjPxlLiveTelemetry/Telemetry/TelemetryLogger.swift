import CloudKit
import Foundation
import os

public protocol TelemetryLogging: Actor, Sendable {
    nonisolated var currentSessionId: String { get }

    nonisolated func logEvent(
        name: String,
        property1: String?,
    )

    func activate(enabled: Bool) async
    func setEnabled(_ enabled: Bool) async
    func flush() async
    func shutdown() async
}

public extension TelemetryLogging {
    nonisolated func logEvent(
        name: String,
        property1: String? = nil
    ) {
        logEvent(
            name: name,
            property1: property1
        )
    }
}

public actor TelemetryLogger: TelemetryLogging {
    public struct Configuration: Sendable {
        public let batchSize: Int
        public let flushInterval: TimeInterval
        public let maxRetries: Int

        public init(batchSize: Int, flushInterval: TimeInterval, maxRetries: Int) {
            self.batchSize = batchSize
            self.flushInterval = flushInterval
            self.maxRetries = maxRetries
        }

        public static let `default` = Configuration(
            batchSize: 10,
            flushInterval: 30.0,
            maxRetries: 3
        )
    }

    private enum LoggerState: Sendable {
        case initializing
        case ready(enabled: Bool)
    }

    private let client: CloudKitClientProtocol
    private let config: Configuration
    private var flushTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private let deviceInfo: DeviceInfo
    private var pending: [TelemetryEvent] = []
    private var queuedEvents: [TelemetryEvent] = []
    private var offline = false
    private nonisolated let continuationLock = OSAllocatedUnfairLock<AsyncStream<TelemetryEvent>.Continuation?>(initialState: nil)
    private nonisolated let shutdownLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private nonisolated let stateLock = OSAllocatedUnfairLock<LoggerState>(initialState: .initializing)
    public nonisolated let currentSessionId: String
    private let deferredStream: AsyncStream<TelemetryEvent>

    public init(
        configuration: Configuration = .default,
        client: CloudKitClientProtocol
    ) {
        self.client = client
        self.config = configuration
        self.deviceInfo = DeviceInfo.current
        self.currentSessionId = UUID().uuidString
        var continuation: AsyncStream<TelemetryEvent>.Continuation!
        let stream = AsyncStream<TelemetryEvent> { cont in
            continuation = cont
        }
        let capturedContinuation = continuation
        continuationLock.withLock { $0 = capturedContinuation }
        self.deferredStream = stream
    }

    // without nonisolated, this must be called async which isn't compatible for the constructor scenario
    public nonisolated func logEvent(
        name: String,
        property1: String? = nil,
    ) {
        let isShutdown = shutdownLock.withLock { $0 }
        guard !isShutdown else { return }

        let state = stateLock.withLock { $0 }
        switch state {
        case .initializing:
            // Queue the event for later processing
            let event = TelemetryEvent(
                name: name,
                timestamp: Date(),
                sessionId: currentSessionId,
                deviceInfo: deviceInfo,
                threadId: Self.currentThreadId(),
                property1: property1
            )
            Task { await self.queueEvent(event) }
        case .ready(enabled: false):
            // Discard - telemetry is disabled
            return
        case .ready(enabled: true):
            // Normal path - process the event
            let event = TelemetryEvent(
                name: name,
                timestamp: Date(),
                sessionId: currentSessionId,
                deviceInfo: deviceInfo,
                threadId: Self.currentThreadId(),
                property1: property1
            )
            _ = continuationLock.withLock { continuation in
                continuation?.yield(event)
            }
        }
    }

    private func queueEvent(_ event: TelemetryEvent) {
        queuedEvents.append(event)
    }

    public func activate(enabled: Bool) async {
        if enabled {
            // Start consuming and validating only when telemetry is actually enabled
            await bootstrap(stream: deferredStream)

            // Flush queued events to pending
            for event in queuedEvents {
                _ = continuationLock.withLock { continuation in
                    continuation?.yield(event)
                }
            }
        }
        queuedEvents.removeAll()
        stateLock.withLock { $0 = .ready(enabled: enabled) }
    }

    public func setEnabled(_ enabled: Bool) async {
        stateLock.withLock { $0 = .ready(enabled: enabled) }
    }

    public func flush() async {
        guard !pending.isEmpty else { return }

        let eventsToSend = pending
        pending.removeAll()

        await sendEvents(eventsToSend)
    }

    public func shutdown() async {
        shutdownLock.withLock { $0 = true }
        flushTask?.cancel()
        consumeTask?.cancel()
        continuationLock.withLock { $0?.finish() }
        await flush()
    }

    private func bootstrap(stream: AsyncStream<TelemetryEvent>) async {
        consumeTask = Task { await consume(stream: stream) }
        
        guard await client.validateSchema() else {
            offline = true
            return
        }
        
        flushTask = Task { await periodicFlush() }
    }

    private func periodicFlush() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.flushInterval))
            await self.flush()
        }
    }

    private func consume(stream: AsyncStream<TelemetryEvent>) async {
        for await event in stream {
            let isShutdown = shutdownLock.withLock { $0 }
            guard !isShutdown, !offline else { continue }
            pending.append(event)
            if pending.count >= config.batchSize {
                await flush()
            }
        }
    }

    private func sendEvents(_ events: [TelemetryEvent]) async {
        let records = events.map { $0.toCKRecord() }

        await withRetries(maxAttempts: config.maxRetries) {
            try await self.saveRecords(records)
        }
    }

    private func saveRecords(_ records: [CKRecord]) async throws {
        try await client.save(records: records)
    }

    private func withRetries<T>(
        maxAttempts: Int,
        operation: @Sendable () async throws -> T
    ) async -> T? {
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch {
                if attempt == maxAttempts {
                    print("Telemetry failed after \(maxAttempts) attempts: \(error)")
                    return nil
                }

                let delay = TimeInterval(pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        return nil
    }

    public nonisolated static func currentThreadId() -> String {
        #if canImport(Darwin)
        return String(pthread_mach_thread_np(pthread_self()))
        #else
        return String(Thread.current.hashValue)
        #endif
    }
}

/// A no-op logger that discards all events. Used as a default environment value.
public actor NoopTelemetryLogger: TelemetryLogging {
    public nonisolated let currentSessionId: String = ""

    public init() {}

    public nonisolated func logEvent(name: String, property1: String?) {}
    public func activate(enabled: Bool) async {}
    public func setEnabled(_ enabled: Bool) async {}
    public func flush() async {}
    public func shutdown() async {}
}
