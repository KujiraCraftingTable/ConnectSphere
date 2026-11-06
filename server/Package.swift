// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "connectsphere-server",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // HTTP server, routing, middleware, WebSocket, async HTTP client.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.106.0"),
        // PostgresKit re-exports SQLKit. Raw parameterized SQL against Postgres,
        // which is how every query in the Node backend is written. No Fluent.
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.13.0"),
        // HMAC-SHA256 for the hand-rolled HS256 JWT (jsonwebtoken-compatible).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
        // Background jobs + scheduled tasks on Redis (BullMQ counterpart).
        .package(url: "https://github.com/vapor/queues.git", from: "1.13.0"),
        .package(url: "https://github.com/vapor/queues-redis-driver.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Queues", package: "queues"),
                .product(name: "QueuesRedisDriver", package: "queues-redis-driver"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("DisableOutwardActorInference"),
    ]
}
