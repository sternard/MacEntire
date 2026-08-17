import XCTest
@testable import MacEntireCore

final class PackageInspectorTests: XCTestCase {
    func testPackageInspectionRunsGitOffMainThread() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireInspectorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let repository = packagesDirectory.appendingPathComponent("Example-App", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "https://github.com/sternard/Example-App\n".write(
            to: packagesDirectory.appendingPathComponent("packages.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "#!/usr/bin/env bash\n".write(
            to: repository.appendingPathComponent("scripts/run-app.sh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let gitRunner = InspectionGitRunner()
        let inspector = PackageInspector(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: gitRunner
        )

        let packages = try await inspector.packages()

        XCTAssertEqual(packages.first?.state, .ready)
        XCTAssertFalse(gitRunner.wasCalledOnMainThread)
    }
}

private final class InspectionGitRunner: GitRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calledOnMainThread = false

    var wasCalledOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calledOnMainThread
    }

    func run(_ arguments: [String], description: String) throws -> String {
        lock.lock()
        calledOnMainThread = calledOnMainThread || Thread.isMainThread
        lock.unlock()

        if arguments.contains("rev-parse") {
            return arguments[1]
        }
        return "https://github.com/sternard/Example-App.git"
    }
}
