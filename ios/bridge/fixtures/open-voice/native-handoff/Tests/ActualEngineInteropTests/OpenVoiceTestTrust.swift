import Foundation
import Security
import CryptoKit
@testable import FloatingVoiceCore

#if DEBUG
/// Test-target-only policy for one generated loopback leaf, not a general trust bypass.
/// No private key or trust-store installation is involved. Both pin AND SSL host policy
/// must pass; certificate network fetching is disabled, including for failures.
struct OpenVoiceTestTrust {
    let certificateDER: Data
    let pin: Data
    // Test-only observations; identical trust/pin/host decisions, no bypass.
    var diagnostic: ((String,Bool,Int) -> Void)?
    init(certificateDER: Data, expectedPin: Data? = nil) {
        self.certificateDER = certificateDER
        pin = expectedPin ?? Data(SHA256.hash(data: certificateDER))
    }
    var handler: OpenVoiceTestTLSChallenge {
        { challenge, completion in
            diagnostic?("host",challenge.protectionSpace.host == "127.0.0.1",0)
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  challenge.protectionSpace.host == "127.0.0.1",
                  let trust = challenge.protectionSpace.serverTrust,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  let anchor = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
                completion(.cancelAuthenticationChallenge, nil); return
            }
            guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "127.0.0.1" as CFString)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  evaluate(trust),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                completion(.cancelAuthenticationChallenge, nil); return
            }
            let leafDER = SecCertificateCopyData(leaf) as Data
            let actual = Data(SHA256.hash(data: leafDER))
            let matches = actual.count == pin.count && zip(actual,pin).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            diagnostic?("pin",matches && leafDER == certificateDER,0)
            guard matches && leafDER == certificateDER else {
                completion(.cancelAuthenticationChallenge, nil); return
            }
            completion(.useCredential, URLCredential(trust: trust))
        }
    }
    private func evaluate(_ trust: SecTrust) -> Bool {
        var error: CFError?
        let result = SecTrustEvaluateWithError(trust,&error)
        diagnostic?("ssl-policy",result,error.map { CFErrorGetCode($0) } ?? 0)
        return result
    }
}

/// Preserves actual system TLS/delegate/header/send/receive/ping operations. Only
/// the exposure of a real successful commit-send completion can be held by a test.
@MainActor final class OpenVoiceHeldSystemCompletion: OpenVoiceSocketTask {
    private let underlying: OpenVoiceSocketTask
    private var held: ((Error?) -> Void)?
    private var barrierTimer: DispatchWorkItem?
    private var closed = false
    var onHeld: (() -> Void)?
    var onPriorReceiveHandled: ((String) -> Void)?
    private var priorFrameType: String?
    init(_ underlying: OpenVoiceSocketTask) { self.underlying = underlying }
    func resume() { underlying.resume() }
    func receive(completion: @escaping (Result<Data,Error>) -> Void) {
        // The owner requesting the next actual receive proves its preceding receive
        // returned through the production adapter/client (including deferred events).
        if let priorFrameType { self.priorFrameType = nil; onPriorReceiveHandled?(priorFrameType) }
        underlying.receive { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let data) = result { self?.priorFrameType = (try? OpenVoiceWire.parse(data))?["type"].string }
                completion(result)
            }
        }
    }
    func ping(completion: @escaping (Error?) -> Void) { underlying.ping(completion: completion) }
    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        let isCommit = (try? OpenVoiceWire.parse(Data(text.utf8)))?["type"] == .string("input_audio_buffer.commit")
        underlying.send(text) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.closed else { completion(OpenVoiceFailure("local_failure")); return }
                guard isCommit && error == nil else { completion(error); return }
                guard self.held == nil else { completion(OpenVoiceFailure("local_failure")); return }
                self.held = completion
                let timeout = DispatchWorkItem { [weak self] in MainActor.assumeIsolated {
                    self?.release(OpenVoiceFailure("local_failure"))
                } }
                self.barrierTimer = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
                self.onHeld?()
            }
        }
    }
    func release(_ error: Error? = nil) {
        barrierTimer?.cancel(); barrierTimer = nil
        let completion = held; held = nil; completion?(error)
    }
    func cancel() {
        guard !closed else { return }; closed = true
        release(OpenVoiceFailure("local_failure")); underlying.cancel()
    }
}
#endif
