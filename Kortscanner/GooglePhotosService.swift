import Foundation
import UIKit
import AuthenticationServices
import CryptoKit
import Security
import Combine

@MainActor
final class GooglePhotosService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GooglePhotosService()
    @Published private(set) var signedIn = false
    @Published private(set) var albumURL: URL?
    @Published private(set) var accountID = ""
    private var albumID = ""
    private var overrideToken: String?
    private var overrideExpiry = Date.distantPast
    private var generation = 0
    private let scopes = [
        "https://www.googleapis.com/auth/photoslibrary.appendonly",
        "https://www.googleapis.com/auth/photoslibrary.readonly.appcreateddata"
    ]
    private var authSession: ASWebAuthenticationSession?
    var configured: Bool { Self.validClientID(clientID) }
    static func validClientID(_ value: String) -> Bool {
        value.range(of: "^[0-9]+-[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil
    }
    private var clientID: String { Keychain.get("googleClientID") }
    private var scheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func restore() async {
        accountID = Keychain.get("googleAccountID")
        signedIn = configured && !accountID.isEmpty && !Keychain.get("googleRefreshToken").isEmpty
        if signedIn { loadAlbum() }
    }
    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw APIError.message("Sikkert login kunne ikke startes. Prøv igen.")
        }
        return Self.base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func signIn() async throws {
        guard configured else {
            throw APIError.message("Indtast dit iOS OAuth-klient-id i Indstillinger først.")
        }
        guard authSession == nil else { throw APIError.message("Et Google-login er allerede åbent.") }
        let verifier = try randomToken()
        let state = try randomToken()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let redirect = scheme + ":/oauth2redirect"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: (["openid"] + scopes).joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account")
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: scheme) { callback, error in
                Task { @MainActor in
                    self.authSession = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: APIError.message(error == nil ? "Google-login blev afbrudt." : "Google-login kunne ikke fuldføres.")) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.authSession = session
            if !session.start() { self.authSession = nil; continuation.resume(throwing: APIError.message("Loginvinduet kunne ikke åbnes.")) }
        }
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first(where: { $0.name == key })?.value }
        if let code = value("error"), GoogleDiagnostics.safeCodes.contains(code) {
            DebugLog.shared.error("Google OAuth: \(code)")
            throw APIError.message(GoogleDiagnostics.message(status: 400, code: code))
        }
        guard callback.scheme == scheme, value("state") == state,
              let code = value("code"), value("error") == nil else { throw APIError.message("Login blev afbrudt eller kunne ikke kontrolleres.") }
        let result = try await tokenRequest(["client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"])
        guard let access = result["access_token"] as? String,
              let refresh = result["refresh_token"] as? String,
              let granted = result["scope"] as? String,
              scopes.allSatisfy({ granted.components(separatedBy: " ").contains($0) }) else {
            throw APIError.message("Google gav ikke begge Fotos-tilladelser. Prøv login igen.")
        }
        var identityRequest = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        identityRequest.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        let identity = try JSONSerialization.jsonObject(with: await HTTP.data(identityRequest)) as? [String: Any]
        guard let id = identity?["sub"] as? String, !id.isEmpty else { throw APIError.message("Google-kontoen kunne ikke kontrolleres.") }
        generation += 1
        resetAlbum()
        try Keychain.set(refresh, key: "googleRefreshToken")
        try Keychain.set(id, key: "googleAccountID")
        accountID = id
        signedIn = true
        overrideToken = access
        overrideExpiry = Date().addingTimeInterval((result["expires_in"] as? Double) ?? 3600)
        loadAlbum()
        DebugLog.shared.info("Google-login lykkedes")
    }
    private func loadAlbum() {
        albumID = UserDefaults.standard.string(forKey: "googleAlbum-\(accountID)") ?? ""
        albumURL = UserDefaults.standard.string(forKey: "googleAlbumURL-\(accountID)").flatMap(URL.init(string:))
    }
    func signOut() {
        generation += 1
        resetAlbum()
        do {
            try Keychain.set("", key: "googleRefreshToken")
            try Keychain.set("", key: "googleAccountID")
        } catch { DebugLog.shared.error("Google-login kunne ikke ryddes fra Keychain") }
        overrideToken = nil
        overrideExpiry = .distantPast
        signedIn = false
        accountID = ""
        DebugLog.shared.info("Google logget ud; album nulstillet")
    }
    func resetAlbum() {
        if !accountID.isEmpty {
            UserDefaults.standard.removeObject(forKey: "googleAlbum-\(accountID)")
            UserDefaults.standard.removeObject(forKey: "googleAlbumURL-\(accountID)")
        }
        albumID = ""
        albumURL = nil
    }
    private func googleData(_ original: URLRequest) async throws -> Data {
        var request = original
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.message("Google svarede ikke. Tjek forbindelsen.") }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            var candidates = [object?["error"] as? String, error?["status"] as? String].compactMap { $0 }
            let details = error?["details"] as? [[String: Any]] ?? []
            let errors = error?["errors"] as? [[String: Any]] ?? []
            candidates += (details + errors).compactMap { $0["reason"] as? String }
            let code = candidates.first(where: { GoogleDiagnostics.safeCodes.contains($0) }) ?? "ukendt"
            DebugLog.shared.error("Google HTTP \(response.statusCode) · \(code)")
            if response.statusCode == 401 { throw APIError.http(401) }
            throw APIError.message(GoogleDiagnostics.message(status: response.statusCode, code: code))
        }
        return data
    }
    private func tokenRequest(_ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data = try await googleData(request)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.message("Google-login kunne ikke fornyes.") }
        return result
    }
    private func token(force: Bool = false) async throws -> String {
        guard signedIn, configured else { throw APIError.message("Log ind på Google i Indstillinger.") }
        if !force, let overrideToken, overrideExpiry.timeIntervalSinceNow > 60 { return overrideToken }
        let refresh = Keychain.get("googleRefreshToken")
        guard !refresh.isEmpty else { throw APIError.message("Log ind på Google igen.") }
        let result = try await tokenRequest(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        guard let access = result["access_token"] as? String else { throw APIError.message("Google-login kunne ikke fornyes. Log ind igen.") }
        if let refresh = result["refresh_token"] as? String { try Keychain.set(refresh, key: "googleRefreshToken") }
        overrideToken = access
        overrideExpiry = Date().addingTimeInterval((result["expires_in"] as? Double) ?? 3600)
        return access
    }
    private func send(_ original: URLRequest) async throws -> Data {
        let currentGeneration = generation
        for attempt in 0...1 {
            var request = original
            let access = try await token(force: attempt == 1)
            guard currentGeneration == generation else { throw CancellationError() }
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            do {
                let data = try await googleData(request)
                guard currentGeneration == generation else { throw CancellationError() }
                return data
            } catch APIError.http(401) where attempt == 0 {
                overrideToken = nil
                DebugLog.shared.info("Google Fotos: 401; fornyer token og prøver én gang igen")
            }
        }
        throw APIError.http(401)
    }
    private func json(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: "https://photoslibrary.googleapis.com/v1/" + path) else { throw APIError.message("Ugyldig Google-anmodning.") }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data = try await send(request)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.message("Google Fotos returnerede et ukendt svar.")
        }
        return result
    }
    func ensureAlbum() async throws -> String {
        if !albumID.isEmpty { return albumID }
        var pageToken: String?
        repeat {
            var path = "albums?pageSize=50"
            if let pageToken { path += "&pageToken=" + (pageToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") }
            let result = try await json(path)
            let albums = result["albums"] as? [[String: Any]] ?? []
            if let album = albums.first(where: { ($0["title"] as? String) == "Kortscanner" && ($0["isWriteable"] as? Bool) == true }) {
                try storeAlbum(album)
                return albumID
            }
            pageToken = result["nextPageToken"] as? String
        } while pageToken != nil
        let created = try await json("albums", body: ["album": ["title": "Kortscanner"]])
        try storeAlbum(created)
        DebugLog.shared.info("Google Fotos-album oprettet")
        return albumID
    }
    private func storeAlbum(_ album: [String: Any]) throws {
        guard let id = album["id"] as? String, !id.isEmpty else { throw APIError.message("Google-albummet kunne ikke oprettes.") }
        albumID = id
        albumURL = (album["productUrl"] as? String).flatMap(URL.init(string:))
        UserDefaults.standard.set(id, forKey: "googleAlbum-\(accountID)")
        UserDefaults.standard.set(albumURL?.absoluteString, forKey: "googleAlbumURL-\(accountID)")
    }
    func upload(_ data: Data, name: String, description: String) async throws {
        let album = try await ensureAlbum()
        var request = URLRequest(url: URL(string: "https://photoslibrary.googleapis.com/v1/uploads")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("image/jpeg", forHTTPHeaderField: "X-Goog-Upload-Content-Type")
        request.setValue("raw", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue(name, forHTTPHeaderField: "X-Goog-Upload-File-Name")
        let tokenData = try await send(request)
        guard let uploadToken = String(data: tokenData, encoding: .utf8), !uploadToken.isEmpty else {
            throw APIError.message("Google kunne ikke modtage billedet.")
        }
        let result = try await json("mediaItems:batchCreate", body: [
            "albumId": album, "albumPosition": ["position": "LAST_IN_ALBUM"],
            "newMediaItems": [["description": description,
                              "simpleMediaItem": ["fileName": name, "uploadToken": uploadToken]]]
        ])
        guard let item = (result["newMediaItemResults"] as? [[String: Any]])?.first else {
            throw APIError.message("Google returnerede ingen uploadstatus.")
        }
        let code = ((item["status"] as? [String: Any])?["code"] as? Int) ?? 0
        if code == 16 { throw APIError.http(401) }
        if code == 5 { throw APIError.http(404) }
        guard code == 0, item["mediaItem"] != nil else { throw APIError.message("Google kunne ikke oprette billedet. Det bliver i køen.") }
    }
    func test() async throws {
        _ = try await json("albums?pageSize=1")
    }
}
