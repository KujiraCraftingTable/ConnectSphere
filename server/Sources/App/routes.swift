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
    NotificationsController.register(routes: api)
    MessagesController.register(routes: api)
    SearchController.register(routes: api)

    // Socket.IO v4 / Engine.IO 4 shim — mounted on `app` (not `api`), auth via
    // the SIO CONNECT frame's `{token}`, not a header.
    SocketIOShim.register(app)
    // Phase 8 — entities / wards / locations
}
