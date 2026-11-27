// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "tv_cast",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "tv-cast", targets: ["tv_cast"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "tv_cast",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Apple's privacy manifest: no tracking, no data collected, no
                // required-reason APIs.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
