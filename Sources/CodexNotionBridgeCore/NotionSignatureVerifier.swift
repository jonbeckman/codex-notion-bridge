import CryptoKit
import Foundation

public enum NotionSignatureVerifier {
    public static func expectedSignature(body: Data, verificationToken: String) -> String {
        let key = SymmetricKey(data: Data(verificationToken.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256=\(hex)"
    }

    public static func verify(signatureHeader: String?, body: Data, verificationToken: String) -> Bool {
        guard let signatureHeader else { return false }
        let expected = expectedSignature(body: body, verificationToken: verificationToken)
        return timingSafeEqual(Data(expected.utf8), Data(signatureHeader.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    private static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for index in lhs.indices {
            diff |= lhs[index] ^ rhs[index]
        }
        return diff == 0
    }
}
