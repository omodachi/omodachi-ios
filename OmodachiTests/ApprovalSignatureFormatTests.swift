import CryptoKit
import Foundation
import Security
import XCTest
@testable import Omodachi

/// UX-3 §1. What the Secure Enclave actually hands us, against what core's
/// verifier actually parses.
///
/// AUTH-1 and AUTH-2 both shipped with the device half verified only by a
/// *software* fake device (`omodachi-core/tests/pam/fake_device.py`), and
/// AUTH-2 §7.7 said in as many words that a real enclave had never signed
/// anything we checked. Then Leo's iPad enrolled a real enclave key and every
/// approval came back `biometric_signature_invalid`, so the first question was
/// whether the enclave's encodings were the ones core expects.
///
/// They are, and this file is the proof that does not need an enclave:
///
/// * `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` emits DER
///   `SEQUENCE { INTEGER r, INTEGER s }`, which is what core parses — and
///   *not* the raw 64-byte `r || s` that core refuses.
/// * `SecKeyCopyExternalRepresentation` on the public half emits the 65-byte
///   X9.63 point `04 || X || Y`, which is what core reads; the 91-byte SPKI
///   DER wrapping is the other thing core accepts, and both are checked.
/// * The message is the ASCII field list, signed *whole*: SHA-256 happens
///   inside the signing call, so nothing pre-hashes and nothing base64s.
///
/// A simulator cannot mint an enclave key, so the key here is a software P-256
/// one — but it goes through `ApprovalKeyStore.signature(_:over:)` and
/// `ApprovalKeyStore.identity(of:)`, the same two calls the enclave path uses.
/// The encoding is a property of the algorithm constant, not of where the
/// private half lives. What the enclave adds on top — the access control and
/// the biometric — cannot change the bytes, and §1 of the report records the
/// real iPad's own public key as a fixture below.
final class ApprovalSignatureFormatTests: XCTestCase {
    /// A software P-256 key with no access control, so the test needs no face.
    private func softwareKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]
        ]
        var failure: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &failure) else {
            failure?.release()
            throw XCTSkip("this runtime refused to mint a P-256 key")
        }
        return key
    }

    private var message: Data {
        get throws {
            try XCTUnwrap(ApprovalMessage.approval(
                hostID: "0f1e2d3c4b5a69788796a5b4c3d2e1f0",
                approvalID: "appr_5f4f0874fda999d980c1184663d93b94",
                nonce: String(repeating: "n", count: 43), service: "polkit-1",
                user: "alex", deviceID: "ios-cd64141c-a2f5-443d-80a3-ecb10895ed2e"))
        }
    }

    /// The signature is DER, and it is DER that CryptoKit — an implementation
    /// that shares no code with core's — agrees verifies over these bytes.
    func testTheSigningPathEmitsDEROverTheWholeMessage() throws {
        let key = try softwareKey()
        let message = try message
        let signature = try ApprovalKeyStore.signature(key, over: message)

        XCTAssertEqual(signature.first, 0x30, "core parses a DER SEQUENCE and nothing else")
        XCTAssertEqual(Int(signature[1]), signature.count - 2, "DER length must cover the body exactly")
        XCTAssertNotEqual(signature.count, 64, "a raw r||s signature is refused by core")
        XCTAssertTrue((70...72).contains(signature.count), "P-256 DER is 70-72 bytes, got \(signature.count)")

        let identity = try ApprovalKeyStore.identity(of: key)
        let point = try XCTUnwrap(Data(base64Encoded: identity.publicKey))
        let verifier = try P256.Signing.PublicKey(x963Representation: point)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        XCTAssertTrue(verifier.isValidSignature(parsed, for: message))
        XCTAssertFalse(verifier.isValidSignature(parsed, for: message + Data([0x21])))
    }

    /// The public half is the bare X9.63 point, 65 bytes, leading `04`. Core
    /// also accepts the 91-byte SPKI DER, and both describe the same point.
    func testThePublicHalfIsTheX963PointCoreReads() throws {
        let key = try softwareKey()
        let identity = try ApprovalKeyStore.identity(of: key)
        let point = try XCTUnwrap(Data(base64Encoded: identity.publicKey))
        XCTAssertEqual(point.count, 65)
        XCTAssertEqual(point.first, 0x04)
        XCTAssertFalse(identity.secureEnclave, "a software key must not claim an enclave")

        // core's SPKI branch: the standard 26-byte prefix plus the same point.
        let prefix = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
                           0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                           0x42, 0x00])
        let spki = prefix + point
        XCTAssertEqual(spki.count, 91)
        XCTAssertEqual(try P256.Signing.PublicKey(derRepresentation: spki).x963Representation, point)
    }

    /// The real iPad's own enrolled public key, read off `omarchy` at
    /// `~/.config/omodachi/biometric-keys.json` on 2026-09-21 (public half
    /// only; the private half is in the enclave and cannot be exported).
    ///
    /// This is the fixture that closes AUTH-2 §7.7: a key a real Secure Enclave
    /// generated, in the encoding the app sent and core stored. It parses as a
    /// 65-byte X9.63 point on P-256, which is why enrolment verified — and
    /// therefore why the approval failure was never about the encoding.
    func testTheRealEnclaveKeyFromLeosIPadIsAnX963Point() throws {
        let base64 = "BDyL0tQQHMaZF/kEvOGWJflKFsvi8au4OOW+1lTPxBQp+GE3qd/GcS9rd5iU0mVaSvrZ2xOIFPB4KwiHMgGS1Lc="
        let point = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(point.count, 65)
        XCTAssertEqual(point.first, 0x04)
        XCTAssertNoThrow(try P256.Signing.PublicKey(x963Representation: point))
    }
}
