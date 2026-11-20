import Foundation

/// Splits a server-sent events stream into events, one byte at a time, so it
/// can sit directly on `URLSession.AsyncBytes`. Only `event` and `data` matter
/// to the services here; ids, retry hints and comments are dropped.
struct ServerSentEvents {
    struct Event: Equatable {
        var name: String?
        var data: String
    }

    private var line: [UInt8] = []
    private var name: String?
    private var data: [String] = []

    /// Returns an event when this byte ends one (the blank line after its fields).
    mutating func feed(_ byte: UInt8) -> Event? {
        guard byte == UInt8(ascii: "\n") else { line.append(byte); return nil }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return process(text)
    }

    /// Flushes an event the stream ended in the middle of.
    mutating func finish() -> Event? {
        if !line.isEmpty, let event = feed(UInt8(ascii: "\n")) { return event }
        return process("")
    }

    private mutating func process(_ line: String) -> Event? {
        if line.isEmpty {
            defer { name = nil; data = [] }
            return data.isEmpty ? nil : Event(name: name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            let rest = line[line.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "data": data.append(String(value))
        case "event": name = String(value)
        default: break
        }
        return nil
    }
}

/// Why a request to a user-configured online service didn't produce an answer.
enum OnlineFailure: LocalizedError, Equatable {
    /// No usable address, key or model yet.
    case notConfigured
    case offline
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "这个服务还没有配置完整。")
        case .offline: String(localized: "没有网络连接。")
        case .failed(let message): message
        }
    }
}

/// What online services share, whatever they are used for: parsing the address
/// the user typed, sending a request, streaming SSE events, and turning HTTP and
/// network failures into an `OnlineFailure` a person can read.
enum OnlineService {
    enum StreamStep: Equatable {
        case text(String)
        case ignore
        case done
    }

    /// Parses an `http(s)://` endpoint root, stripping trailing slashes and any
    /// accidental endpoint path suffix the user pasted (such as `/chat/completions`).
    static func cleanBaseURL(_ address: String, strippingSuffixes suffixes: [String] = []) -> URL? {
        var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        for suffix in suffixes where trimmed.lowercased().hasSuffix(suffix.lowercased()) {
            trimmed.removeLast(suffix.count)
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// A trimmed key, or nil when there is none: local servers may not want one.
    static func nonEmptyKey(_ key: String?) -> String? {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    /// Sends the request and returns the body as it arrives, or throws an
    /// `OnlineFailure` built from the status and the service's own message.
    static func send(_ request: URLRequest, session: URLSession) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return bytes }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= 8192 { break }
        }
        throw failure(status: http.statusCode, body: body)
    }

    /// Sends a non-streaming request and collects the whole response body.
    static func receive(_ request: URLRequest, session: URLSession) async throws -> Data {
        var data = Data()
        for try await byte in try await send(request, session: session) { data.append(byte) }
        return data
    }

    /// Runs an SSE request and yields the growing text after each delta.
    static func stream(_ makeRequest: @Sendable @escaping () throws -> URLRequest, session: URLSession,
                       step: @Sendable @escaping (ServerSentEvents.Event) throws -> StreamStep) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await send(makeRequest(), session: session)
                    var events = ServerSentEvents()
                    var text = ""
                    var stopped = false
                    func handle(_ event: ServerSentEvents.Event) throws -> Bool {
                        switch try step(event) {
                        case .text(let delta) where !delta.isEmpty:
                            text += delta
                            continuation.yield(text)
                            return false
                        case .text, .ignore:
                            return false
                        case .done:
                            return true
                        }
                    }
                    for try await byte in bytes {
                        if let event = events.feed(byte), try handle(event) { stopped = true; break }
                    }
                    if !stopped, let event = events.finish() { _ = try handle(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : failure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func failure(status: Int, body: Data) -> OnlineFailure {
        let reason: String = switch status {
        case 401: String(localized: "API Key 无效。")
        case 403: String(localized: "这个 Key 没有权限使用该模型或接口。")
        case 404: String(localized: "找不到接口或模型，检查服务地址和模型名。")
        case 429, 456: String(localized: "额度用完或请求太频繁，稍后再试。")
        case 500...: String(localized: "服务暂时不可用（\(status)）。")
        default: String(localized: "请求失败（\(status)）。")
        }
        guard let message = message(in: body) else { return .failed(reason) }
        return .failed("\(reason)\(message.prefix(160))")
    }

    /// The human-readable part of an error body: `{"error": {"message": …}}`,
    /// `{"error": "…"}`, `{"message": …}`, or a short plain-text body.
    static func message(in body: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
            if let message = json["message"] as? String { return message }
            if let detail = json["detail"] as? String { return detail }
            return nil
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix("<") ? nil : text
    }

    /// Maps whatever a request threw onto an `OnlineFailure`; cancellation stays cancellation.
    static func failure(_ error: Error) -> Error {
        if error is CancellationError || error is OnlineFailure { return error }
        guard let error = error as? URLError else { return OnlineFailure.failed(error.localizedDescription) }
        switch error.code {
        case .cancelled: return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return OnlineFailure.offline
        case .timedOut: return OnlineFailure.failed(String(localized: "请求超时。"))
        case .cannotFindHost, .cannotConnectToHost, .unsupportedURL:
            return OnlineFailure.failed(String(localized: "连不上服务，检查服务地址。"))
        default: return OnlineFailure.failed(error.localizedDescription)
        }
    }
}
