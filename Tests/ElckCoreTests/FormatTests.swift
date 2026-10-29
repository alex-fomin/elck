import CryptoKit
import XCTest
@testable import ElckCore

final class FormatTests: XCTestCase {
    func testRoundTripAndReseal() throws {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let plaintext = Data("привет".utf8)
        let sealed = try ElckFormat.seal(plaintext: plaintext, to: privateKey.publicKey)
        let opened = try ElckFormat.open(container: sealed, agree: privateKey.sharedSecretFromKeyAgreement)
        XCTAssertEqual(opened.plaintext, plaintext)

        let updated = Data("ещё".utf8)
        let rewritten = try ElckFormat.write(plaintext: updated, fileKey: opened.fileKey, wrapHeader: opened.wrapHeader)
        let again = try ElckFormat.open(container: rewritten, agree: privateKey.sharedSecretFromKeyAgreement)
        XCTAssertEqual(again.plaintext, updated)
        XCTAssertNotEqual(sealed, rewritten)
    }

    func testEmptyPlaintext() throws {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let sealed = try ElckFormat.seal(plaintext: Data(), to: privateKey.publicKey)
        let opened = try ElckFormat.open(container: sealed, agree: privateKey.sharedSecretFromKeyAgreement)
        XCTAssertEqual(opened.plaintext, Data())
    }

    func testBadMagic() {
        XCTAssertThrowsError(try ElckFormat.open(container: Data("nope".utf8), agree: { _ in throw ElckError.crypto })) { error in
            XCTAssertEqual(error as? ElckError, .badMagic)
        }
    }

    func testTruncated() {
        XCTAssertThrowsError(try ElckFormat.open(container: Data("ELK1".utf8), agree: { _ in throw ElckError.crypto })) { error in
            XCTAssertEqual(error as? ElckError, .truncated)
        }
    }

    func testWrongKey() throws {
        let sealed = try ElckFormat.seal(plaintext: Data("x".utf8), to: P256.KeyAgreement.PrivateKey().publicKey)
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try ElckFormat.open(container: sealed, agree: other.sharedSecretFromKeyAgreement))
    }
}
