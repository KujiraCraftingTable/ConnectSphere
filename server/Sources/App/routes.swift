import Vapor

/// Route mounts. Grows one phase at a time; the prefixes and order mirror
/// `backend/index.js` lines 542–561.
func routes(_ app: Application) throws {
    let api = app.grouped("api")

    AuthController.register(routes: api)
    UsersController.register(routes: api)
    PostsController.register(routes: api)          // + nested /posts/:id interactions
    FeedController.register(routes: api)
    TagsController.register(routes: api)
    EventsController.register(routes: api)
    StoriesController.register(routes: api)
    LinkPreviewController.register(routes: api)
    ConnectionsController.register(routes: api)
    CommunitiesController.register(routes: api)
    // notifications inbox ported next
    // Phase 4 — messages  (+ the /socket.io shim, mounted on `app` not `api`)
    // Phase 5 — search / entities
    // Phase 8 — wards / locations
}
