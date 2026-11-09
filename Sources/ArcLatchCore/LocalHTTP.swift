import Foundation

public enum LocalHTTPError: Error, Equatable {
    case refused
    case timedOut
    case status(Int, String?)
    case transport(String)
}

/// URLSession helper for loopback endpoints only: finite timeouts, system
/// proxies bypassed, and redirects refused rather than followed off-origin.
public final class LocalHTTP: @unchecked Sendable {
    public static let shared = LocalHTTP()

    private let session: URLSession
    private let delegate: NoRedirectDelegate

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // never follow redirects to other origins
        }
    }

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]      // bypass any system proxy
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        delegate = NoRedirectDelegate()
        session = URLSession(configuration: config, delegate: delegate,
                             delegateQueue: nil)
        retainDelegate()
    }

    private func retainDelegate() {
        objc_setAssociatedObject(session, "arclatch.delegate", delegate,
                                 .OBJC_ASSOCIATION_RETAIN)
    }

    private func url(port: Int, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    public func get(port: Int, path: String,
                    timeout: TimeInterval = 5) async -> Result<Data, LocalHTTPError> {
        await send(port: port, path: path, method: "GET", body: nil, timeout: timeout)
    }

    public func post(port: Int, path: String, json body: [String: Any],
                     timeout: TimeInterval) async -> Result<Data, LocalHTTPError> {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure(.transport("body encode failed"))
        }
        return await send(port: port, path: path, method: "POST",
                          body: data, timeout: timeout)
    }

    private func send(port: Int, path: String, method: String, body: Data?,
                      timeout: TimeInterval) async -> Result<Data, LocalHTTPError> {
        var req = URLRequest(url: url(port: port, path: path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-http response"))
            }
            if http.statusCode >= 400 {
                let snippet = String(data: data.prefix(600), encoding: .utf8)
                return .failure(.status(http.statusCode, snippet))
            }
            return .success(data)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotOpenFile, .networkConnectionLost:
                return .failure(.refused)
            case .timedOut:
                return .failure(.timedOut)
            default:
                if (urlError.userInfo.keys.contains("kCFStreamErrorCodeKey")) {
                    let code = urlError.userInfo["kCFStreamErrorCodeKey"] as? Int ?? -1
                    if code == ECONNREFUSED { return .failure(.refused) }
                }
                return .failure(.transport(urlError.localizedDescription))
            }
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    public func json(port: Int, path: String,
                     timeout: TimeInterval = 5) async -> Result<[String: Any], LocalHTTPError> {
        switch await get(port: port, path: path, timeout: timeout) {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.transport("invalid json"))
            }
            return .success(obj)
        case .failure(let e):
            return .failure(e)
        }
    }

    public func postJSON(port: Int, path: String, body: [String: Any],
                         timeout: TimeInterval) async -> Result<[String: Any], LocalHTTPError> {
        switch await post(port: port, path: path, json: body, timeout: timeout) {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.transport("invalid json"))
            }
            return .success(obj)
        case .failure(let e):
            return .failure(e)
        }
    }
}
