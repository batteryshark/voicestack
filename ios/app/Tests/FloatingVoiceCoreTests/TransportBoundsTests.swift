import Foundation
import Testing
@testable import FloatingVoiceCore

private final class NoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // A transport fake; never opens a socket.
    override func stopLoading() {}
}

@Suite struct TransportBoundsTests {
    @Test func slowConsumerFailsInsteadOfDroppingPCMOrGrowingWithoutBound() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkProtocol.self]
        let request = URLRequest(url: URL(string: "https://synthetic.invalid/fixture")!)
        let stream = HTTPChunkStream(request, idleTimeout: 1, configuration: config)
        let task = URLSession.shared.dataTask(with: request) // Never resumed.
        // Exercise the production delegate's real AsyncThrowingStream buffer with no consumer yet.
        for _ in 0..<33 { stream.urlSession(.shared, dataTask: task, didReceive: Data(repeating: 7, count: 640)) }
        do { _ = try await stream.collect(); Issue.record("overflow must fail, never truncate audio silently") }
        catch HTTPError.tooLarge { }
        catch { Issue.record("wrong failure: \(error)") }
        stream.cancel()
    }
    @Test func oversizedSingleChunkFailsBeforeEnqueue() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkProtocol.self]
        let request = URLRequest(url: URL(string: "https://synthetic.invalid/fixture")!)
        let stream = HTTPChunkStream(request, idleTimeout: 1, configuration: config)
        stream.urlSession(.shared, dataTask: URLSession.shared.dataTask(with: request), didReceive: Data(repeating: 0, count: 1024 * 1024 + 1))
        do { _ = try await stream.collect(); Issue.record("single chunk must be bounded") }
        catch HTTPError.tooLarge { }
        catch { Issue.record("wrong failure: \(error)") }
        stream.cancel()
    }
}
