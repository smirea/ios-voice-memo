// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ios-voice-memo",
	platforms: [
		.iOS(.v17),
		.macOS(.v14),
	],
	products: [
		.executable(name: "ios-voice-memo", targets: ["App"]),
	],
	targets: [
		.executableTarget(name: "App"),
	]
)