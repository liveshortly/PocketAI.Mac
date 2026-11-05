import Foundation

/// COM-10: `pocketai://activate?key=<key>` from the website's "Open in PocketAI".
enum ActivateLink {
    /// Where "Get licence" and every Pro-needed prompt send people.
    static let licencePage = URL(string: "https://pocket.liveshortly.com/licence?from=mac")!

    /// The key in an activate link, or nil for any other URL or an empty key.
    static func key(in url: URL) -> String? {
        guard url.scheme?.lowercased() == "pocketai", url.host?.lowercased() == "activate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let key = items.first(where: { $0.name == "key" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// The address a key was issued to, read from its (unverified) payload for
    /// the confirm sheet only. Activation itself verifies the signature.
    static func email(inKey key: String) -> String? {
        guard key.hasPrefix("key/"), let dot = key.lastIndex(of: ".") else { return nil }
        var b64 = String(key[key.index(key.startIndex, offsetBy: 4)..<dot])
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let candidates = [(obj["user"] as? [String: Any])?["email"], (obj["license"] as? [String: Any])?["email"], obj["email"]]
        return candidates.compactMap { $0 as? String }.first { $0.contains("@") }
    }
}
