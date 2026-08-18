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
        try writeExecutableLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh", isDirectory: false)
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

    func testOverlappingPackageInspectionsShareInFlightWork() async throws {
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
        try writeExecutableLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh", isDirectory: false)
        )
        let gitRunner = BlockingInspectionGitRunner()
        let inspector = PackageInspector(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: gitRunner
        )

        let firstInspection = Task { try await inspector.packages() }
        XCTAssertEqual(gitRunner.firstInspectionStarted.wait(timeout: .now() + 1), .success)
        let secondInspection = Task { try await inspector.packages() }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(gitRunner.topLevelCallCount, 1)
        gitRunner.allowInspectionToFinish.signal()
        let firstPackages = try await firstInspection.value
        let secondPackages = try await secondInspection.value
        XCTAssertEqual(firstPackages, secondPackages)
        XCTAssertEqual(gitRunner.topLevelCallCount, 1)
    }

    func testForcedInspectionStartsFreshWorkAfterInFlightInspection() async throws {
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
        try writeExecutableLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh", isDirectory: false)
        )
        let gitRunner = BlockingInspectionGitRunner()
        let inspector = PackageInspector(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: gitRunner
        )

        let firstInspection = Task { try await inspector.packages() }
        XCTAssertEqual(gitRunner.firstInspectionStarted.wait(timeout: .now() + 1), .success)
        let forcedInspection = Task { try await inspector.packages(forceRefresh: true) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gitRunner.topLevelCallCount, 1)

        gitRunner.allowInspectionToFinish.signal()
        _ = try await firstInspection.value
        _ = try await forcedInspection.value
        XCTAssertEqual(gitRunner.topLevelCallCount, 2)
    }

    func testRegularInspectionJoinsQueuedForcedInspection() async throws {
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
        try writeExecutableLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh", isDirectory: false)
        )
        let gitRunner = BlockingInspectionGitRunner(firstTopLevelResult: temporaryRoot.path)
        let inspector = PackageInspector(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: gitRunner
        )

        let firstInspection = Task { try await inspector.packages() }
        XCTAssertEqual(gitRunner.firstInspectionStarted.wait(timeout: .now() + 1), .success)
        let forcedInspection = Task { try await inspector.packages(forceRefresh: true) }
        try await Task.sleep(for: .milliseconds(100))
        let regularInspection = Task { try await inspector.packages() }

        gitRunner.allowInspectionToFinish.signal()
        let stalePackages = try await firstInspection.value
        let forcedPackages = try await forcedInspection.value
        let regularPackages = try await regularInspection.value

        XCTAssertEqual(
            stalePackages.first?.state,
            .unavailable("Example-App already exists but is not a Git repository.")
        )
        XCTAssertEqual(forcedPackages.first?.state, .ready)
        XCTAssertEqual(regularPackages, forcedPackages)
        XCTAssertEqual(gitRunner.topLevelCallCount, 2)
    }
}

private func writeExecutableLauncher(at url: URL) throws {
    try "#!/usr/bin/env bash\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
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

private final class BlockingInspectionGitRunner: GitRunning, @unchecked Sendable {
    let firstInspectionStarted = DispatchSemaphore(value: 0)
    let allowInspectionToFinish = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let firstTopLevelResult: String?
    private var topLevelCalls = 0

    init(firstTopLevelResult: String? = nil) {
        self.firstTopLevelResult = firstTopLevelResult
    }

    var topLevelCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return topLevelCalls
    }

    func run(_ arguments: [String], description: String) throws -> String {
        if arguments.contains("rev-parse") {
            lock.lock()
            topLevelCalls += 1
            let isFirstCall = topLevelCalls == 1
            lock.unlock()
            if isFirstCall {
                firstInspectionStarted.signal()
                allowInspectionToFinish.wait()
            }
            return isFirstCall ? (firstTopLevelResult ?? arguments[1]) : arguments[1]
        }
        return "https://github.com/sternard/Example-App.git"
    }
}
