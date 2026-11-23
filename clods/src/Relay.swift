import CryptoKit
import Foundation
import Security

/// The four values that connect this app to the relay. They arrive once, by pairing
/// (a `clods://pair?d=...` link from the Mac), and are kept in the Keychain. Nothing is built in.
struct Pairing: Codable, Equatable {
    var h: String // relay host
    var a: String // relay public key
    var k: String // access key
    var e: String // encryption key, hex
}

enum Config {
    private static let service = "clods.pairing"
    private static var cached: Pairing?

    /// Shared Keychain group for the phone app and its notification extension; empty on the watch.
    private static var group: String? {
        let g = (Bundle.main.object(forInfoDictionaryKey: "ClodsKeychainGroup") as? String) ?? ""
        return g.isEmpty ? nil : g
    }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static var pairing: Pairing? {
        if let cached { return cached }
        var q = query()
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        cached = try? JSONDecoder().decode(Pairing.self, from: data)
        return cached
    }

    static var isPaired: Bool { pairing != nil }

    static func save(_ p: Pairing) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
        cached = p
    }

    /// Accepts the pairing link, or just its `d` value.
    static func parse(_ text: String) -> Pairing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = trimmed
        if let comps = URLComponents(string: trimmed), let v = comps.queryItems?.first(where: { $0.name == "d" })?.value {
            d = v
        }
        var b64 = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let p = try? JSONDecoder().decode(Pairing.self, from: data),
              !p.h.isEmpty, p.e.count == 64 else { return nil }
        return p
    }

    static var encoded: String? {
        guard let p = pairing, let data = try? JSONEncoder().encode(p) else { return nil }
        return data.base64EncodedString()
    }

    static var host: String { pairing?.h ?? "" }
    static var anon: String { pairing?.a ?? "" }
    static var key: String { pairing?.k ?? "" }
    static var e2e: String { pairing?.e ?? "" }
}

/// AES-256-GCM, base64(nonce | ciphertext | tag). Matches the bridge on the Mac.
enum Box {
    private static var key: SymmetricKey {
        var bytes = [UInt8]()
        var hex = Substring(Config.e2e)
        while hex.count >= 2 {
            bytes.append(UInt8(hex.prefix(2), radix: 16) ?? 0)
            hex = hex.dropFirst(2)
        }
        return SymmetricKey(data: Data(bytes))
    }

    static func open(_ b64: String?) -> String? {
        guard Config.isPaired, let b64, let data = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func seal(_ text: String) -> String? {
        guard Config.isPaired, let box = try? AES.GCM.seal(Data(text.utf8), using: key) else { return nil }
        return box.combined?.base64EncodedString()
    }
}

struct SessionRow: Decodable {
    let id: String
    let machine: String
    let state: String
    let name_enc: String?
    let detail_enc: String?
    let updated_at: String
}

struct AskRow: Decodable {
    let id: String
    let session_id: String
    let body_enc: String?
    let status: String
    let answer_enc: String?
}

struct Clod: Identifiable, Hashable {
    let id: String
    let machine: String
    let state: String
    let name: String
    let detail: String
    let updated: Date
    var askID: String?
    var ask: String?
    var answer: String?
    var askStatus: String?

    var needsYou: Bool { state == "waiting" || state == "permission" }

    var rank: Int {
        switch state {
        case "waiting": return 0
        case "permission": return 1
        case "working": return 2
        case "done": return 3
        default: return 4
        }
    }

    var stateLabel: String {
        switch state {
        case "waiting": return "Waiting on you"
        case "permission": return "Needs permission"
        case "working": return "Working"
        case "done": return "Done"
        default: return "Idle"
        }
    }
}

enum Relay {
    private static func request(_ method: String, _ path: String, body: Data? = nil, prefer: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://\(Config.host)/rest/v1/\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue(Config.anon, forHTTPHeaderField: "apikey")
        req.setValue(Config.key, forHTTPHeaderField: "x-clods-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "prefer") }
        req.httpBody = body
        return req
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ s: String) -> Date {
        iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
    }

    static func fetch() async throws -> [Clod] {
        guard Config.isPaired else { return [] }
        async let s = URLSession.shared.data(for: request("GET", "clods_sessions?select=*&order=updated_at.desc&limit=80"))
        async let a = URLSession.shared.data(for: request(
            "GET",
            "clods_asks?select=id,session_id,body_enc,status,answer_enc&status=in.(open,answered)&order=created_at.desc&limit=80"
        ))
        let sessions = try JSONDecoder().decode([SessionRow].self, from: try await s.0)
        let asks = (try? JSONDecoder().decode([AskRow].self, from: try await a.0)) ?? []
        var latest: [String: AskRow] = [:]
        for ask in asks where latest[ask.session_id] == nil { latest[ask.session_id] = ask }

        return sessions.map { row in
            let ask = latest[row.id]
            return Clod(
                id: row.id,
                machine: row.machine,
                state: row.state,
                name: Box.open(row.name_enc) ?? "session",
                detail: Box.open(row.detail_enc) ?? "",
                updated: date(row.updated_at),
                askID: ask?.id,
                ask: Box.open(ask?.body_enc),
                answer: Box.open(ask?.answer_enc),
                askStatus: ask?.status
            )
        }
        .sorted { ($0.rank, $1.updated) < ($1.rank, $0.updated) }
    }

    @discardableResult static func answer(askID: String, text: String) async -> Bool {
        guard !askID.isEmpty, let sealed = Box.seal(text) else { return false }
        let body: [String: String] = [
            "status": "answered",
            "answer_enc": sealed,
            "answered_at": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        let req = request("PATCH", "clods_asks?id=eq.\(askID)&status=eq.open", body: data, prefer: "return=minimal")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse).map { $0.statusCode < 300 } ?? false
    }

    static func register(token: String, platform: String, env: String) async {
        guard Config.isPaired else { return }
        let body: [String: String] = [
            "token": token, "platform": platform, "env": env,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let req = request("POST", "clods_devices?on_conflict=token", body: data, prefer: "resolution=merge-duplicates,return=minimal")
        _ = try? await URLSession.shared.data(for: req)
    }
}
