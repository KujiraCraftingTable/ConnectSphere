import Foundation

/// Posted after a socket reconnect (not the initial connect) so per-conversation
/// view models can re-emit `join_conversation`, server-side room membership does
/// not survive a disconnect, but registered event listeners do.
extension Notification.Name {
    static let webSocketDidReconnect = Notification.Name("WebSocketClient.didReconnect")
}

/// Errors surfaced through an `emit(...completion:)` ack callback.
enum WebSocketError: Error {
    /// The server's ack payload was shaped like `{"error": "..."}`.
    case serverError(String)
    /// No ack arrived within the timeout window.
    case timeout
    /// `emit` was called while the socket wasn't connected.
    case notConnected
}

/// Lightweight Socket.IO v4 client built on top of URLSessionWebSocketTask.
/// Implements EIO4 handshake, heartbeat ping/pong, and SIO event dispatch.
@Observable
final class WebSocketClient {

    enum ConnectionState { case disconnected, connecting, connected }

    private(set) var connectionState: ConnectionState = .disconnected

    static let shared = WebSocketClient()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var token: String?
    private var handlers: [String: [String: (Any) -> Void]] = [:]

    // Socket.IO ACK bookkeeping: an incrementing id per acked emit, the pending
    // callback keyed by that id, and a timeout work item so a callback can never
    // leak forever if the server never acks.
    private var nextAckId = 0
    private var pendingAcks: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var ackTimeoutWorkItems: [Int: DispatchWorkItem] = [:]
    private let ackTimeout: TimeInterval = 10

    // Auto-reconnect: turned on in connect(), turned off by an explicit disconnect() (logout)
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    /// True once the very first successful connect has happened. Distinguishes
    /// the initial connect from a later reconnect (only the latter posts `.webSocketDidReconnect`).
    private var hasConnectedOnce = false

    private init() {}

    // MARK: - Public API

    func connect(token: String) {
        guard connectionState == .disconnected else { return }
        self.token = token
        shouldReconnect = true
        reconnectWorkItem?.cancel()
        connectionState = .connecting

        // Derive ws(s):// URL from the http(s):// base
        let wsBase = APIConfig.serverBase
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://",  with: "ws://")
        guard let url = URL(string: "\(wsBase)/socket.io/?EIO=4&transport=websocket") else { return }

        session = URLSession(configuration: .default)
        task = session?.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        connectionState = .disconnected
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        // A same-process logout→login must not have its fresh connect
        // misclassified as a reconnect (which would post `.webSocketDidReconnect`
        // to listeners that were never actually dropped).
        hasConnectedOnce = false
        failAllPendingAcks(.notConnected)
    }

    /// Emit a Socket.IO event with an optional JSON-serialisable payload.
    /// When `completion` is supplied, the emit is tagged with an ack id
    /// (`42<id>[...]`) and the callback resolves once the server's ACK packet
    /// (`43<id>[...]`) arrives, is rejected as `{"error": "..."}`, or times out.
    /// Without a completion, this is the original fire-and-forget behaviour.
    func emit(_ event: String, _ data: Any? = nil, completion: ((Result<Any?, Error>) -> Void)? = nil) {
        guard connectionState == .connected else {
            completion?(.failure(WebSocketError.notConnected))
            return
        }
        var array: [Any] = [event]
        if let data { array.append(data) }

        guard let completion else {
            guard let json = try? JSONSerialization.data(withJSONObject: array),
                  let str  = String(data: json, encoding: .utf8) else { return }
            sendRaw("42\(str)")
            return
        }

        guard let json = try? JSONSerialization.data(withJSONObject: array),
              let str  = String(data: json, encoding: .utf8) else {
            completion(.failure(WebSocketError.serverError("Could not encode message")))
            return
        }

        let ackId = nextAckId
        nextAckId += 1
        pendingAcks[ackId] = completion

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ackTimeoutWorkItems.removeValue(forKey: ackId)
            if let cb = self.pendingAcks.removeValue(forKey: ackId) {
                cb(.failure(WebSocketError.timeout))
            }
        }
        ackTimeoutWorkItems[ackId] = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout, execute: timeoutWork)

        sendRaw("42\(ackId)\(str)")
    }

    /// Register a tagged handler for a named Socket.IO event.
    /// Using a tag lets each view independently manage its own handler
    /// without clobbering handlers registered by other views.
    func on(_ event: String, tag: String, handler: @escaping (Any) -> Void) {
        handlers[event, default: [:]][tag] = handler
    }

    /// Remove a single tagged handler.
    func off(_ event: String, tag: String) {
        handlers[event]?.removeValue(forKey: tag)
    }

    /// Remove ALL handlers for an event.
    func off(_ event: String) {
        handlers.removeValue(forKey: event)
    }

    // MARK: - Private receive loop

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg { self.handlePacket(text) }
                self.receiveLoop()
            case .failure:
                DispatchQueue.main.async { self.handleDisconnect() }
            }
        }
    }

    // MARK: - EIO / SIO packet dispatch

    private func handlePacket(_ text: String) {
        guard let first = text.first else { return }
        switch first {
        case "0": // EIO open → send SIO connect with auth token
            let auth: [String: String] = ["token": token ?? ""]
            let jsonStr = (try? JSONSerialization.data(withJSONObject: auth))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            sendRaw("40\(jsonStr)")

        case "2": // EIO ping → EIO pong
            sendRaw("3")

        case "4": // EIO message → SIO payload
            handleSIOPacket(String(text.dropFirst()))

        default: break
        }
    }

    private func handleSIOPacket(_ text: String) {
        guard let first = text.first else { return }
        switch first {
        case "0": // SIO connected
            DispatchQueue.main.async {
                let isReconnect = self.hasConnectedOnce
                self.connectionState = .connected
                self.hasConnectedOnce = true
                self.reconnectAttempt = 0
                self.startHeartbeat()
                if isReconnect {
                    NotificationCenter.default.post(name: .webSocketDidReconnect, object: nil)
                }
            }

        case "1": // SIO disconnect
            DispatchQueue.main.async { self.handleDisconnect() }

        case "2": // SIO event  42[...]
            dispatchEvent(String(text.dropFirst()))

        case "3": // SIO ack    43<id>[...]
            handleAck(String(text.dropFirst()))

        default: break
        }
    }

    private func dispatchEvent(_ jsonStr: String) {
        guard let data  = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let event = array.first as? String else { return }
        let payload: Any = array.count > 1 ? array[1] : NSNull()
        DispatchQueue.main.async {
            self.handlers[event]?.values.forEach { $0(payload) }
        }
    }

    /// Parses a Socket.IO ACK packet body (`<id>[payload]`, id digits first, then
    /// the JSON array) and resolves the matching pending callback registered by
    /// `emit(...completion:)`. A payload shaped like `{"error": "..."}` resolves
    /// as a failure; anything else resolves as a success.
    private func handleAck(_ text: String) {
        var idDigits = ""
        var rest = Substring(text)
        while let first = rest.first, first.isNumber {
            idDigits.append(first)
            rest.removeFirst()
        }
        guard let ackId = Int(idDigits) else { return }

        var payload: Any?
        if let data = String(rest).data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            payload = array.first
        }

        DispatchQueue.main.async {
            self.ackTimeoutWorkItems.removeValue(forKey: ackId)?.cancel()
            guard let callback = self.pendingAcks.removeValue(forKey: ackId) else { return }
            if let dict = payload as? [String: Any], let errMsg = dict["error"] as? String {
                callback(.failure(WebSocketError.serverError(errMsg)))
            } else {
                callback(.success(payload))
            }
        }
    }

    /// Fails every still-pending ack callback (used on disconnect, so a caller
    /// awaiting an ack doesn't hang until its 10s timeout after the socket died).
    private func failAllPendingAcks(_ error: WebSocketError) {
        let pending = pendingAcks
        pendingAcks.removeAll()
        ackTimeoutWorkItems.values.forEach { $0.cancel() }
        ackTimeoutWorkItems.removeAll()
        pending.values.forEach { $0(.failure(error)) }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        pingTimer?.invalidate()
        // Server's pingInterval is 25 s; send EIO ping every 20 s to stay ahead
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.sendRaw("2")
        }
    }

    // MARK: - Helpers

    private func sendRaw(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func handleDisconnect() {
        connectionState = .disconnected
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        failAllPendingAcks(.notConnected)
        scheduleReconnect()
    }

    /// Automatically reconnects with exponential backoff (2s → 4s → … up to a 30s cap)
    /// after a connection drop. Previously a single drop left chat "dead" until the app was reopened.
    private func scheduleReconnect() {
        guard shouldReconnect, let token else { return }
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30)

        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect, self.connectionState == .disconnected else { return }
            self.connect(token: token)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
