import Foundation

/// A single SSE session, pinned to the same hub endpoint for its entire life.
/// Cancelling the consumer closes the socket; PocketBase then drops its topics.
enum BeszelRealtimeConnection {
    static func updates(endpoint: URL, token: String, systemIDs: [String],
                        configuration: URLSessionConfiguration,
                        onUnauthorized: @escaping @Sendable () async -> Void) -> AsyncThrowingStream<RealtimeSystemUpdate, Error> {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 15
        // Collection requests have a short resource timeout; an SSE response
        // intentionally stays open. Idle connections still time out and retry.
        config.timeoutIntervalForResource = 86_400
        config.urlCache = nil
        let session = URLSession(configuration: config)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(max(1, systemIDs.count * 2))) { continuation in
            let task = Task {
                defer { session.invalidateAndCancel() }
                do {
                    try await withTaskCancellationHandler {
                        let topics = try Dictionary(uniqueKeysWithValues: Set(systemIDs).map { (try topic(for: $0), $0) })
                        let url = endpoint.appendingPathComponent("api/realtime")
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        let (bytes, response) = try await session.bytes(for: request)
                        try check(response)
                        guard (response as? HTTPURLResponse)?.mimeType == "text/event-stream" else {
                            throw URLError(.badServerResponse)
                        }
                        var parser = ServerSentEventParser()
                        var subscribed = false
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            guard let event = try parser.append(byte) else { continue }
                            if event.name == "PB_CONNECT" {
                                guard !subscribed else { throw URLError(.badServerResponse) }
                                let connection = try JSONDecoder().decode(ConnectEvent.self, from: event.data)
                                var subscription = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                                subscription.httpMethod = "POST"
                                subscription.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                subscription.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                subscription.httpBody = try JSONSerialization.data(withJSONObject: [
                                    "clientId": connection.clientId, "subscriptions": topics.keys.sorted()
                                ])
                                let (_, response) = try await session.data(for: subscription)
                                try check(response)
                                subscribed = true
                            } else if subscribed, let systemID = topics[event.name] {
                                let metrics = try JSONDecoder().decode(RealtimeMetrics.self, from: event.data)
                                continuation.yield(RealtimeSystemUpdate(systemID: systemID, metrics: metrics))
                            }
                        }
                        // A clean EOF also needs a reconnect, just like a failed socket.
                        throw URLError(.networkConnectionLost)
                    } onCancel: {
                        session.invalidateAndCancel()
                    }
                } catch {
                    if case BeszelAPIError.httpError(let code, _) = error, code == 401 || code == 403 {
                        await onUnauthorized()
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
        }
    }

    static func topic(for systemID: String) throws -> String {
        let options = try JSONSerialization.data(withJSONObject: ["query": ["system": systemID]], options: [.sortedKeys, .withoutEscapingSlashes])
        // Match PocketBase JS's encodeURIComponent exactly, including the topic
        // spelling used by other clients sharing an agent's realtime worker.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let query = String(decoding: options, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed)!
        return "rt_metrics?options=\(query)"
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw BeszelAPIError.httpError(statusCode: response.statusCode, url: response.url?.absoluteString ?? "")
        }
    }

    private struct ConnectEvent: Decodable { let clientId: String }
}

struct ServerSentEventParser {
    struct Event {
        let name: String
        let data: Data
    }

    private var line: [UInt8] = []
    private var name = "message"
    private var data: [String] = []
    private var byteCount = 0
    private var previousWasCR = false
    private var isFirstLine = true
    let maximumEventBytes: Int

    init(maximumEventBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumEventBytes = maximumEventBytes
    }

    mutating func append(_ byte: UInt8) throws -> Event? {
        if byte == 10 && previousWasCR {
            previousWasCR = false
            return nil
        }
        previousWasCR = byte == 13
        byteCount += 1
        guard byteCount <= maximumEventBytes else { throw URLError(.dataLengthExceedsMaximum) }
        guard byte == 10 || byte == 13 else {
            line.append(byte)
            return nil
        }
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            let event = data.isEmpty ? nil : Event(name: name, data: Data(data.joined(separator: "\n").utf8))
            name = "message"
            data.removeAll(keepingCapacity: true)
            byteCount = 0
            return event
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch parts[0] {
        case "event": name = value.isEmpty ? "message" : value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}
