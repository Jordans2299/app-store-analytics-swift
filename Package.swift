// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppStoreAnalytics",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "AppStoreAnalytics", targets: ["AppStoreAnalytics"])],
    targets: [
        .target(
            name: "AppStoreAnalytics",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "AppStoreAnalyticsTests", dependencies: ["AppStoreAnalytics"])
    ]
)

