import Foundation
import AppKit
import Network
import Security
import OpenSongCore

/// Signing in to Spotify: opens the browser, catches the redirect on a loopback port, swaps the
/// code for tokens, and keeps them renewed.
///
/// An actor because the token is shared mutable state that any request may ask for at any moment,
/// and a refresh must not happen twice concurrently.
actor SpotifySignIn: SpotifyUserTokens {
    private let clientID: String
    private let clientSecret: String
    private let redirectURI: String
    private var refreshing: Task<SpotifySession?, Never>?

    init(clientID: String, clientSecret: String,
         redirectURI: String = SpotifyAuth.defaultRedirectURI) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.redirectURI = redirectURI
    }

    var isSignedIn: Bool { SpotifyKeychain.load() != nil }

    // MARK: the token SpotifyClient asks for

    func userAccessToken() async -> String? {
        guard let session = SpotifyKeychain.load() else { return nil }
        if session.isFresh() { return session.accessToken }
        // One refresh at a time: several requests hitting an expired token would otherwise each
        // spend the refresh token, and Spotify may rotate it.
        if let inFlight = refreshing { return await inFlight.value?.accessToken }
        let task = Task { () -> SpotifySession? in
            try? await self.refresh(session)
        }
        refreshing = task
        let renewed = await task.value
        refreshing = nil
        return renewed?.accessToken
    }

    private func refresh(_ session: SpotifySession) async throws -> SpotifySession {
        let data = try await postToken(SpotifyAuth.refreshBody(refreshToken: session.refreshToken))
        let renewed = try SpotifyAuth.session(fromTokenJSON: data,
                                              existingRefresh: session.refreshToken)
        SpotifyKeychain.save(renewed)
        return renewed
    }

    // MARK: signing in

    /// Open the browser, wait for the redirect, and store the session. Throws if the user refuses,
    /// closes the browser (via the timeout), or Spotify rejects the exchange.
    func signIn() async throws {
        let state = SpotifyAuth.randomState()
        guard let url = SpotifyAuth.authorizeURL(clientID: clientID, redirectURI: redirectURI,
                                                 state: state) else {
            throw SpotifyAuth.AuthError.badTokenResponse("couldn't build the authorize URL")
        }
        let listener = try CallbackListener(port: SpotifyAuth.callbackPort(of: redirectURI))
        // The listener starts before the browser opens: Spotify can redirect faster than a
        // late-started listener would be ready for.
        async let target = listener.waitForCallback()
        NSWorkspace.shared.open(url)
        let requestTarget = try await target
        let code = try SpotifyAuth.codeFromCallback(requestTarget, expectedState: state)
        let data = try await postToken(SpotifyAuth.exchangeBody(code: code, redirectURI: redirectURI))
        SpotifyKeychain.save(try SpotifyAuth.session(fromTokenJSON: data))
    }

    func signOut() { SpotifyKeychain.clear() }

    private func postToken(_ body: Data) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        let creds = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}

/// A one-shot HTTP server on the loopback interface, there only to catch Spotify's redirect.
///
/// Spotify requires `http://127.0.0.1` (not `localhost`) for native apps, so the browser lands here
/// rather than on a website we'd have to run.
private final class CallbackListener: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private let lock = NSLock()

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.read(connection)
            }
            listener.start(queue: .main)
            // Don't leave a socket (and the user) hanging if the browser is simply closed.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                // The common cause is the redirect URI not being registered: Spotify then shows
                // "Not matching configuration" in the browser and never redirects back here, so
                // this side just waits. Say so, since the user can't see both halves at once.
                self?.finish(.failure(SpotifyAuth.AuthError.denied(
                    "Spotify never redirected back. Check that the Redirect URI shown in Settings is "
                    + "registered on your Spotify app exactly (dashboard → your app → Settings → "
                    + "Edit → Redirect URIs → Add → Save).")))
            }
        }
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let text = String(data: data, encoding: .utf8),
                  let requestLine = text.split(separator: "\r\n").first else {
                connection.cancel(); return
            }
            // "GET /callback?code=…&state=… HTTP/1.1"
            let parts = requestLine.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            let page = """
            <html><head><meta charset="utf-8"><title>OpenSong</title></head>
            <body style="font-family:-apple-system;text-align:center;padding-top:80px;background:#111;color:#eee">
            <h2>Signed in to Spotify</h2><p>You can close this tab and go back to OpenSong.</p>
            </body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finish(.success(target))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let cont = continuation
        let alreadyDone = finished
        finished = true
        continuation = nil
        lock.unlock()
        guard !alreadyDone, let cont else { return }
        listener.cancel()
        cont.resume(with: result)
    }
}

/// The session lives in the Keychain rather than in preferences: a refresh token is a standing key
/// to someone's Spotify account, which is a different class of secret from an app's own client id.
enum SpotifyKeychain {
    private static let service = "dev.jude.opensong.spotify"
    private static let account = "session"

    static func save(_ session: SpotifySession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> SpotifySession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifySession.self, from: data)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
