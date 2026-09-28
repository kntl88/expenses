import CommonCrypto
import CryptoKit
import Foundation

/// Unlocks the same encrypted vault the web app stores at kntl88/expenses/data/vault.json.
/// Format (index.html encryptData): base64( salt[16] || iv[12] || ciphertext || tag[16] ),
/// key = PBKDF2-SHA256(pin, salt, 310000) → AES-GCM-256. Plaintext is {"token","repo"}.
enum Vault {
    static let owner = "kntl88"
    private static let vaultURL = URL(string: "https://api.github.com/repos/kntl88/expenses/contents/data/vault.json")!
    private static let saltLen = 16, ivLen = 12, iterations: UInt32 = 310_000

    struct Credentials { let token: String; let repo: String? }

    enum VaultError: LocalizedError {
        case fetch(String), format, wrongPin
        var errorDescription: String? {
            switch self {
            case let .fetch(m): return "Couldn't fetch vault: \(m)"
            case .format: return "Vault file has an unexpected format."
            case .wrongPin: return "Wrong PIN."
            }
        }
    }

    static func unlock(pin: String) async throws -> Credentials {
        var req = URLRequest(url: vaultURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw VaultError.fetch("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = (meta["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
              let fileData = Data(base64Encoded: b64),
              let file = try JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              let blob = file["encrypted"] as? String
        else { throw VaultError.format }
        let plain = try decrypt(blob: blob, pin: pin)
        if let obj = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
           let token = obj["token"] as? String {
            return Credentials(token: token, repo: obj["repo"] as? String)
        }
        // Legacy vaults stored only the token string.
        return Credentials(token: plain, repo: nil)
    }

    static func decrypt(blob: String, pin: String) throws -> String {
        guard let p = Data(base64Encoded: blob), p.count > saltLen + ivLen + 16 else { throw VaultError.format }
        let salt = p.prefix(saltLen)
        let iv = p.subdata(in: saltLen..<saltLen + ivLen)
        let body = p.suffix(from: saltLen + ivLen)
        let key = try pbkdf2(password: pin, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: body.dropLast(16), tag: body.suffix(16))
            let out = try AES.GCM.open(box, using: SymmetricKey(data: key))
            guard let s = String(data: out, encoding: .utf8) else { throw VaultError.format }
            return s
        } catch is VaultError {
            throw VaultError.format
        } catch {
            throw VaultError.wrongPin
        }
    }

    private static func pbkdf2(password: String, salt: Data) throws -> Data {
        let pw = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                 &key, key.count)
        }
        guard status == kCCSuccess else { throw VaultError.format }
        return Data(key)
    }
}
