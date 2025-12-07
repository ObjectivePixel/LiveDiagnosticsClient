import Foundation

/// Simple, lightweight telemetry client for ObjectivePixel apps.
///
/// The client batches events and posts JSON payloads to the configured endpoint.
/// Actor isolation keeps it safe to use from any thread.
public actor TelemetryClient {
    public struct Configuration: Sendable, Equatable {
        /// The HTTP endpoint that receives batched events.
        public var endpoint: URL
        /// Optional API key added as an `Authorization` bearer token.
        public var apiKey: String?
        /// Maximum number of events to batch before forcing a flush.
        public var batchSize: Int
        /// Default attributes appended to every event.
        public var defaultAttributes: [String: String]

        public init(
            endpoint: URL,
            apiKey: String? = nil,
            batchSize: Int = 10,
            defaultAttributes: [String: String] = [:]
        ) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.batchSize = max(1, batchSize)
            self.defaultAttributes = defaultAttributes
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public var name: String
        public var attributes: [String: String]
        public var timestamp: Date

        public init(name: String, attributes: [String: String] = [:], timestamp: Date = Date()) {
            self.name = name
            self.attributes = attributes
            self.timestamp = timestamp
        }
    }

    public enum ClientError: Error, Equatable {
        case invalidResponse(statusCode: Int)
        case failedEncoding
    }

    private let configuration: Configuration
    private let session: URLSession
    private let encoder: JSONEncoder
    private var buffer: [Event] = []

    public init(
        configuration: Configuration,
        session: URLSession = .shared,
        encoder: JSONEncoder = JSONEncoder()
    ) {
        let configuredEncoder = encoder
        configuredEncoder.dateEncodingStrategy = .iso8601
        self.configuration = configuration
        self.session = session
        self.encoder = configuredEncoder
    }

    /// Records an event and flushes if the batch is full.
    @discardableResult
    public func track(_ event: Event) async throws -> Bool {
        var merged = event
        configuration.defaultAttributes.forEach { key, value in
            merged.attributes[key, default: value] = merged.attributes[key] ?? value
        }
        buffer.append(merged)
        if buffer.count >= configuration.batchSize {
            return try await flushLocked()
        }
        return false
    }

    /// Sends all buffered events immediately.
    @discardableResult
    public func flush() async throws -> Bool {
        try await flushLocked()
    }

    private func flushLocked() async throws -> Bool {
        guard !buffer.isEmpty else { return false }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        let payload = Payload(events: batch)
        guard let body = try? encoder.encode(payload) else {
            throw ClientError.failedEncoding
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse(statusCode: -1)
        }
        guard 200 ..< 300 ~= httpResponse.statusCode else {
            throw ClientError.invalidResponse(statusCode: httpResponse.statusCode)
        }
        // Allow servers to return instructions or timing info later if needed.
        _ = data
        return true
    }
}

private extension TelemetryClient {
    struct Payload: Codable {
        var events: [Event]
    }
}
