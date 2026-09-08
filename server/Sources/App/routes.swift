import Vapor

/// Route mounts. Grows one phase at a time; the prefixes and order mirror
/// `backend/index.js` lines 542–561.
func routes(_ app: Application) throws {
    let api = app.grouped("api")

    // Phase 1 — try AuthController.register(routes: api)
    // Phase 1 — try UsersController.register(routes: api)
    // Phase 2 — posts / feed / interactions / tags / stories / link-preview / events
    // Phase 3 — communities / connections / notifications
    // Phase 4 — messages  (+ the /socket.io shim, mounted on `app` not `api`)
    // Phase 5 — search / entities
    // Phase 8 — wards / locations

    _ = api  // silence unused until Phase 1 lands
}
