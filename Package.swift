// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "remote-job",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "remote-job-worker", targets: ["RemoteJobWorker"])],
    targets: [.executableTarget(name: "RemoteJobWorker")]
)
