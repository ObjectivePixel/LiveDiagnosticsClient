import Foundation
import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryClientTests: XCTestCase {
    override func setUp() async throws {
        MockURLProtocol.handler = nil
    }

    func testBatchingAndFlush() async throws {
        let expectation = expectation(description: "Request sent")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try request.bodyData()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(MockPayload.self, from: body)
            XCTAssertEqual(decoded.events.count, 2)
            expectation.fulfill()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let session = URLSession(configuration: .mocked)
        let configuration = TelemetryClient.Configuration(
            endpoint: URL(string: "https://example.com/telemetry")!,
            batchSize: 2
        )
        let client = TelemetryClient(configuration: configuration, session: session)

        let first = TelemetryClient.Event(name: "app_start")
        let second = TelemetryClient.Event(name: "screen_view", attributes: ["name": "home"])

        let firstFlush = try await client.track(first)
        XCTAssertFalse(firstFlush, "Should not flush until batch is full")

        let flushed = try await client.track(second)
        XCTAssertTrue(flushed, "Second track should flush the batch")

        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testDefaultAttributesAreMerged() async throws {
        MockURLProtocol.handler = { request in
            let body = try request.bodyData()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(MockPayload.self, from: body)
            XCTAssertEqual(decoded.events.first?.attributes["env"], "prod")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let session = URLSession(configuration: .mocked)
        let configuration = TelemetryClient.Configuration(
            endpoint: URL(string: "https://example.com/telemetry")!,
            batchSize: 1,
            defaultAttributes: ["env": "prod"]
        )
        let client = TelemetryClient(configuration: configuration, session: session)

        _ = try await client.track(.init(name: "test"))
    }
}

private extension URLSessionConfiguration {
    static var mocked: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return configuration
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct MockPayload: Codable {
    var events: [TelemetryClient.Event]
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let data = httpBody { return data }
        if let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }

            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            return data
        }
        throw URLError(.badServerResponse)
    }
}
