import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum EnclaveKey {
    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elck", isDirectory: true)
        return base.appendingPathComponent("enclave-key")
    }

    static func publicKey() throws -> P256.KeyAgreement.PublicKey {
        try load(context: nil).publicKey
    }

    static func agree(with ephemeral: P256.KeyAgreement.PublicKey, reason: String) throws -> SharedSecret {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedReason = reason
        return try load(context: context).sharedSecretFromKeyAgreement(with: ephemeral)
    }

    private static func load(context: LAContext?) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        let url = storageURL
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let context {
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
            }
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
        }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            &cfError
        ) else {
            throw cfError!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.dataRepresentation.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }
}
