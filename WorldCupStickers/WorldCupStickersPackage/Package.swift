// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WorldCupStickersFeature",
    platforms: [.iOS("26.0")],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "WorldCupStickersFeature",
            targets: ["WorldCupStickersFeature"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.48.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "WorldCupStickersFeature",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "WorldCupStickersFeatureTests",
            dependencies: [
                "WorldCupStickersFeature"
            ]
        ),
    ]
)
