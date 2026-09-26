// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MotionCut",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MotionCut", targets: ["MotionCut"])],
    targets: [
        .executableTarget(name: "MotionCut", path: "Sources/MotionCut"),
        .testTarget(name: "MotionCutTests", dependencies: ["MotionCut"], path: "Tests/MotionCutTests")
    ]
)
