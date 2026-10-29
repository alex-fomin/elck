import CryptoKit
import Foundation

public enum ElckError: Error, Equatable {
    case badMagic
    case truncated
    case crypto
}

public enum ElckFormat {
    public static let headerLength = 4 + 65 + 60

    public struct Opened {
        public var plaintext: Data
        public var fileKey: SymmetricKey
        public var wrapHeader: Data
    }

    public static func seal(plaintext: Data, to publicKey: P256.KeyAgreement.PublicKey) throws -> Data {
        let opened = try sealKeepingKey(plaintext: plaintext, to: publicKey)
        return try write(plaintext: opened.plaintext, fileKey: opened.fileKey, wrapHeader: opened.wrapHeader)
    }

    public static func sealKeepingKey(plaintext: Data, to publicKey: P256.KeyAgreement.PublicKey) throws -> Opened {
        let fileKey = SymmetricKey(size: .bits256)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let wrapKey = wrappingKey(shared: shared)
        let rawKey = fileKey.withUnsafeBytes { Data($0) }
        guard let wrapped = try AES.GCM.seal(rawKey, using: wrapKey).combined, wrapped.count == 60 else {
            throw ElckError.crypto
        }
        var header = Data("ELK1".utf8)
        header.append(ephemeral.publicKey.x963Representation)
        header.append(wrapped)
        return Opened(plaintext: plaintext, fileKey: fileKey, wrapHeader: header)
    }

    public static func open(
        container: Data,
        agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret
    ) throws -> Opened {
        guard container.prefix(4) == Data("ELK1".utf8) else { throw ElckError.badMagic }
        guard container.count >= headerLength + 28 else { throw ElckError.truncated }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: container.subdata(in: 4..<69))
        let wrapKey = wrappingKey(shared: try agree(ephemeral))
        let rawKey = try AES.GCM.open(try AES.GCM.SealedBox(combined: container.subdata(in: 69..<headerLength)), using: wrapKey)
        guard rawKey.count == 32 else { throw ElckError.crypto }
        let fileKey = SymmetricKey(data: rawKey)
        let plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: container.suffix(from: headerLength)), using: fileKey)
        return Opened(plaintext: plaintext, fileKey: fileKey, wrapHeader: container.prefix(headerLength))
    }

    public static func write(plaintext: Data, fileKey: SymmetricKey, wrapHeader: Data) throws -> Data {
        guard wrapHeader.count == headerLength else { throw ElckError.truncated }
        guard let body = try AES.GCM.seal(plaintext, using: fileKey).combined else { throw ElckError.crypto }
        return wrapHeader + body
    }

    private static func wrappingKey(shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("elck-salt-v1".utf8),
            sharedInfo: Data("elck-wrap-v1".utf8),
            outputByteCount: 32
        )
    }
}
