import Foundation

public struct ChromeDebugTarget: Equatable, Sendable {
    public let port: Int
    public let browser: String
    public let webSocketDebuggerURL: String?
}

/// Asks a browser's DevTools endpoint who it is.
///
/// The port on the command line is not proof that anything is listening: the
/// browser may have failed to bind it, or exited and left the switch visible in
/// a stale reading. Probing is what turns "claims port 9222" into "this is the
/// browser your extension is talking to", which is the question the command
/// exists to answer.
public struct ChromeDebugProbe: Sendable {
    private let timeout: TimeInterval
    private let session: URLSession

    public init(timeout: TimeInterval = 0.5) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // A DevTools endpoint is always on loopback, and a proxy configured for
        // the user's normal browsing would otherwise swallow the request.
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    /// Asks the socket the browser holds, not merely its port number. With
    /// another process on the same port in the other address family, asking by
    /// number reaches whichever one that host resolves to.
    public func probe(_ listener: ChromeListener) -> ChromeDebugTarget? {
        let port = listener.port
        guard let url = URL(string: "http://\(listener.probeHost):\(port)/json/version") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { payload = data }
            semaphore.signal()
        }
        task.resume()
        // The session timeout should fire first; this only bounds the wait if
        // the callback never arrives at all.
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return nil
        }

        guard let payload,
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let browser = json["Browser"] as? String
        else { return nil }
        return ChromeDebugTarget(
            port: port,
            browser: browser,
            webSocketDebuggerURL: json["webSocketDebuggerUrl"] as? String
        )
    }
}
