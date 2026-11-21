// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatOCR",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "wechat-ocr", targets: ["WeChatOCR"])],
    targets: [
        .executableTarget(name: "WeChatOCR"),
        .testTarget(name: "WeChatOCRTests", dependencies: ["WeChatOCR"])
    ]
)
