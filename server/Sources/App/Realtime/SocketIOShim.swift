import Vapor
import Foundation

/// Engine.IO 4 / Socket.IO v4 protocol shim over a raw Vapor `WebSocket`.
/// The iOS `WebSocketClient` speaks only the websocket transport, one
/// namespace, and a fully-enumerated event set. This reproduces exactly that
/// slice of the protocol, nothing more (no long-polling, no binary frames, no
/// multiplexing).
///
/// Wire framing (what the client sends / expects):
///   - `0{…}`            EIO OPEN            (server → client, first frame)
///   - `40{"token":…}`   SIO CONNECT + auth  (client → server)
///   - `40{"sid":…}`     SIO CONNECT ack     (server → client)
///   - `42[event,arg]`   SIO EVENT           (both ways; `42<id>[…]` when acked)
///   - `43<id>[payload]` SIO ACK             (server → client)
///   - `2` / `3`         EIO ping / pong     (both ways)
///   - `41`              SIO DISCONNECT
enum SocketIOShim {
    static func register(_ app: Application) {
        _ = app.socketHub   // eager-init the shared hub (boot is single-threaded)
        let handler: @Sendable (Request, WebSocket) async -> Void = { req, ws in
            let session = SocketSession(
                ws: ws, db: req.application.db, hub: req.application.socketHub,
                jwtSecret: req.application.appEnv.jwt.secret, logger: req.logger)
            await session.start()
            // `onText` writes a channel-loop-bound box. It MUST be registered
            // on the channel's event loop, not this async Task's executor.
            ws.eventLoop.execute {
                ws.onText { _, text in
                    Task { await session.handle(text) }
                }
            }
            ws.onClose.whenComplete { _ in
                Task { await session.teardown() }
            }
        }
        // engine.io serves `/socket.io/`; Vapor normalises the trailing slash so
        // `["socket.io"]` matches it. Gated to `EIO=4&transport=websocket`.
        let shouldUpgrade: @Sendable (Request) async throws -> HTTPHeaders? = { req in
            let q = req.url.query ?? ""
            guard q.contains("EIO=4"), q.contains("transport=websocket") else { return nil }
            return [:]
        }
        app.webSocket("socket.io", shouldUpgrade: shouldUpgrade, onUpgrade: handler)
    }
}

/// Per-connection state machine. An actor so inbound frames are processed one
/// at a time in arrival order (Socket.IO's per-socket ordering guarantee).
actor SocketSession {
    private let ws: WebSocket
    nonisolated let db: AppDatabase
    nonisolated let hub: SocketHub
    private let jwtSecret: String
    nonisolated let logger: Logger

    private(set) var conn: SocketConn?
    private var heartbeat: Task<Void, Never>?

    init(ws: WebSocket, db: AppDatabase, hub: SocketHub, jwtSecret: String, logger: Logger) {
        self.ws = ws; self.db = db; self.hub = hub; self.jwtSecret = jwtSecret; self.logger = logger
    }

    func start() {
        let sid = UUID().uuidString
        ws.send(#"0{"sid":""# + sid + #"","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#, promise: nil)
        heartbeat = Task { [ws] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { break }
                ws.send("2", promise: nil)   // EIO ping
            }
        }
    }

    func teardown() async {
        heartbeat?.cancel(); heartbeat = nil
        guard let c = conn else { return }
        conn = nil
        hub.remove(c)
        if hub.decPresence(c.userID) {
            await SocketHandlers.broadcastPresence(c.userID, online: false, session: self)
        }
    }

    private func sendRaw(_ s: String) { ws.send(s, promise: nil) }

    // MARK: inbound frame dispatch

    func handle(_ text: String) async {
        if text == "2" { sendRaw("3"); return }          // EIO ping → pong
        if text == "3" { return }                        // EIO pong (server-initiated) → ignore
        guard let f = text.first else { return }
        switch f {
        case "4":                                        // EIO MESSAGE → SIO packet
            let sio = text.dropFirst()
            guard let s = sio.first else { return }
            switch s {
            case "0": await onConnect(String(sio.dropFirst()))
            case "1": ws.close(promise: nil)             // SIO DISCONNECT
            case "2": await onEvent(String(sio.dropFirst()))
            default: break
            }
        case "1":                                        // EIO CLOSE
            ws.close(promise: nil)
        default:
            break
        }
    }

    private func onConnect(_ body: String) async {
        guard conn == nil else { return }
        struct Auth: Decodable { var token: String? }
        let token = (try? JSONDecoder().decode(Auth.self, from: Data(body.utf8)))?.token
        guard let token, !token.isEmpty,
              let payload = try? JWTHS256.verify(token, secret: jwtSecret) else {
            sendRaw(#"44{"message":"Invalid token"}"#)
            ws.close(promise: nil)
            return
        }
        let userID = payload.sub.lowercased()
        let c = SocketConn(sid: UUID().uuidString, userID: userID, ws: ws)
        conn = c
        hub.add(c)
        sendRaw(#"40{"sid":""# + c.sid + #""}"#)

        if hub.incPresence(userID) {
            await SocketHandlers.broadcastPresence(userID, online: true, session: self)
        }
        await SocketHandlers.sendPresenceSnapshot(session: self)
    }

    private func onEvent(_ body: String) async {
        guard let c = conn else { return }
        // Optional leading ack id, then a JSON array `["event", arg?]`.
        var rest = Substring(body)
        var idDigits = ""
        while let ch = rest.first, ch.isNumber { idDigits.append(ch); rest.removeFirst() }
        let ackID = Int(idDigits)
        guard let arr = try? JSONSerialization.jsonObject(with: Data(String(rest).utf8)) as? [Any],
              let event = arr.first as? String else { return }
        let arg: Any? = arr.count > 1 ? arr[1] : nil
        await SocketHandlers.dispatch(event: event, arg: arg, ackID: ackID, conn: c, session: self)
    }

    // MARK: helpers used by SocketHandlers

    func ack(_ ackID: Int?, _ payload: Data) {
        guard let ackID else { return }
        sendRaw(SocketHub.ackFrame(ackID, payload))
    }
    func ackError(_ ackID: Int?, _ message: String) {
        ack(ackID, SocketJSON.data(["error": message]))
    }
    func emitSelf(event: String, _ payload: Data) { conn?.sendRaw(SocketHub.eventFrame(event, payload)) }
}
