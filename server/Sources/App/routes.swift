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
    JobsController.register(routes: api)
    StoriesController.register(routes: api)
    LinkPreviewController.register(routes: api)
    ConnectionsController.register(routes: api)
    SpacesController.register(routes: api)
    MutedWordsController.register(routes: api)
    PeopleController.register(routes: api)
    FollowsController.register(routes: api)
    CommunitiesController.register(routes: api)
    CompaniesController.register(routes: api)       // Work mode company pages
    ExperiencesController.register(routes: api)     // work history + a company's People
    EducationsController.register(routes: api)      // schools on a Hobby profile
    HighlightsController.register(routes: api)      // highlights on a Hobby profile
    ActivityController.register(routes: api)        // your comments and reactions (activity log)
    EndorsementsController.register(routes: api)    // skills + endorsements
    JobBoardController.register(routes: api)        // Jobs tab: recommended, search, saved
    MarketplaceController.register(routes: api)     // Marketplace tab + a listing's page and edits
    ApplicationsController.register(routes: api, app: app)  // Easy Apply + private CVs
    AccountController.register(routes: api)         // verified email + deleting a persona / the account
    NotificationsController.register(routes: api)
    MessagesController.register(routes: api)
    SearchController.register(routes: api)          // + /entities/alias, /locations/clarify
    DatingController.register(routes: api)          // Dating space, 16+ (migration 081)
    InterestsController.register(routes: api)       // the interest picker's catalogue
    SkillsController.register(routes: api)          // the Work skill picker's catalogue
    WardsController.register(routes: api)           // GET /api/wards/* — no auth (matches Node)
    UploadsController.register(routes: api)         // POST /api/uploads — generic media upload

    // Socket.IO v4 / Engine.IO 4 shim — mounted on `app` (not `api`), auth via
    // the SIO CONNECT frame's `{token}`, not a header.
    SocketIOShim.register(app)
}
