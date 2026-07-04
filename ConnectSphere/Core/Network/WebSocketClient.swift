import Foundation

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

    // Auto-reconnect: bật khi connect(), tắt khi disconnect() chủ động (logout)
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?

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
    }

    /// Emit a Socket.IO event with an optional JSON-serialisable payload.
    func emit(_ event: String, _ data: Any? = nil) {
        guard connectionState == .connected else { return }
        var array: [Any] = [event]
        if let data { array.append(data) }
        guard let json = try? JSONSerialization.data(withJSONObject: array),
              let str  = String(data: json, encoding: .utf8) else { return }
        sendRaw("42\(str)")
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
                self.connectionState = .connected
                self.reconnectAttempt = 0
                self.startHeartbeat()
            }

        case "1": // SIO disconnect
            DispatchQueue.main.async { self.handleDisconnect() }

        case "2": // SIO event  42[...]
            dispatchEvent(String(text.dropFirst()))

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
        scheduleReconnect()
    }

    /// Tự kết nối lại với exponential backoff (2s → 4s → … tối đa 30s)
    /// khi rớt mạng — trước đây rớt một lần là chat "chết" tới khi mở lại app.
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
