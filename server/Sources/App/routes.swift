import Vapor

/// Route mounts.
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
    HiddenContactsController.register(routes: api)  // Messages people row: hidden contacts (migration 140)
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
    InterestsController.register(routes: api)       // the interest picker's catalogue
    SkillsController.register(routes: api)          // the Work skill picker's catalogue
    WardsController.register(routes: api)           // GET /api/wards/*. No auth (matches Node)
    UploadsController.register(routes: api)         // POST /api/uploads. Generic media upload
    ReportsController.register(routes: api)         // POST /api/reports. Report anything (migration 089)
    AppealsController.register(routes: api)         // POST /api/appeals. Ask for a review of a decision
    AccountStatusController.register(routes: api)   // GET /api/account-status. Strikes, decisions, your reports
    AdminModerationController.register(routes: api) // /api/admin/moderation. The app-wide review queue
    AdminInterestsController.register(routes: api)  // /api/admin/interests. Review suggested interests
    HRController.register(routes: api, app: app)    // /api/hr. Asking to become a verified HR (migration 126)
    AdminHRController.register(routes: api)         // /api/admin/hr. Reviewing HR requests and new HRs' jobs
    AdminController.register(routes: api)           // /api/admin/stats, /users/lookup. Official account only (migration 104)
    TestHooksController.register(routes: api, app: app) // /api/test. Only with UITEST_HOOKS=1, for the XCUITest suite

    // Socket.IO v4 / Engine.IO 4 shim. Mounted on `app` (not `api`), auth via
    // the SIO CONNECT frame's `{token}`, not a header.
    SocketIOShim.register(app)
}
