import Foundation
import Security
import UIKit

private final class SecItemAdapter: SecureItemAdapter {
    // Preserve the original private application-ID group, service and account.
    private let query: [String: Any]
    private var migrated = false
    init(account: String) {
        query = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "org.example.voicestack") + ".bridge", kSecAttrAccount as String: account]
    }
    func read() -> (Int32, Data?) {
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ data: Data) -> Int32 {
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
    }
    func migrateAccessibility() -> Int32 {
        if migrated { return errSecSuccess }
        // Attribute-only update after a successful read. Never delete/recreate or alter bearer.
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecSuccess { migrated = true }
        return status
    }
    func add(_ data: Data) -> Int32 {
        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(request as CFDictionary, nil)
    }
    func delete() -> Int32 { SecItemDelete(query as CFDictionary) }
}

final class KeychainCredential: DeviceCredentialStore {
    static func makeProof() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CredentialFailure(operation: "random", status: status, malformed: false) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private let store: PreservingCredentialStore
    init(account: String = "device") {
        store = PreservingCredentialStore(adapter: SecItemAdapter(account: account), available: {
            UIApplication.shared.isProtectedDataAvailable && UIApplication.shared.applicationState == .active
        })
    }
    func load() throws -> String? {
        let started = Date()
        do {
            let value = try store.load()
            StageDiagnostics.shared.record(.credentialRead, .complete, since: started, status: value == nil ? -25300 : 0)
            return value
        } catch {
            StageDiagnostics.shared.record(.credentialRead, (error as? CredentialFailure)?.malformed == true ? .malformed : .failed, since: started, status: StageDiagnostics.code(error)); throw error
        }
    }
    func save(_ credential: String) throws {
        let started = Date()
        do { try store.save(credential); StageDiagnostics.shared.record(.credentialWrite, .complete, since: started, status: 0) }
        catch { StageDiagnostics.shared.record(.credentialWrite, (error as? CredentialFailure)?.syntheticGate == true ? .policyGate : ((error as? CredentialFailure)?.malformed == true ? .malformed : .failed), since: started, status: StageDiagnostics.code(error)); throw error }
    }
    func authorizePairing() throws {
        do { try store.authorizePairing() }
        catch { StageDiagnostics.shared.record(.pairing, .policyGate, status: StageDiagnostics.code(error)); throw error }
    }
    func clear() throws {
        let started = Date()
        do { try store.clear(); StageDiagnostics.shared.record(.credentialWrite, .complete, since: started, status: 0) }
        catch { StageDiagnostics.shared.record(.credentialWrite, (error as? CredentialFailure)?.syntheticGate == true ? .policyGate : .failed, since: started, status: StageDiagnostics.code(error)); throw error }
    }
}
