import XCTest
@testable import MacEntireCore

final class PackageSynchronizerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testRefusesToPullRepositoryWithLocalChanges() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(statusOutput: " M README.md")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .localChanges("Example-App"))
        }
        XCTAssertFalse(git.commands.contains { $0.contains("pull") })
    }

    func testCleanRepositoryUsesFastForwardOnlyPull() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains { command in
            command.suffix(2) == ["pull", "--ff-only"]
        })
    }

    func testConfiguredBranchUsesExplicitFastForwardPull() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = FakeGitRunner(currentBranchOutput: "develop", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains { command in
            command.suffix(4) == ["pull", "--ff-only", "origin", "develop"]
        })
    }

    func testRefusesConfiguredBranchMismatch() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = FakeGitRunner(currentBranchOutput: "main", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .branchMismatch(repository: "Example-App", expected: "develop", actual: "main")
            )
        }
        XCTAssertFalse(git.commands.contains { $0.contains("pull") })
    }

    func testMissingRepositoryClonesConfiguredBranch() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: "release/next",
            directoryURL: directory
        )
        let git = FakeGitRunner(statusOutput: "") {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try "#!/usr/bin/env bash\n".write(
                to: directory.appendingPathComponent("scripts/run-app.sh"),
                atomically: true,
                encoding: .utf8
            )
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertEqual(git.commands, [[
            "clone", "--origin", "origin", "--branch", "release/next", "--single-branch",
            "https://github.com/sternard/Example-App", directory.path
        ]])
    }

    func testRefusesRepositoryWithUnexpectedOrigin() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            remoteOutput: "https://github.com/someone-else/Example-App",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .remoteMismatch(
                    expected: "https://github.com/sternard/Example-App",
                    actual: "https://github.com/someone-else/Example-App"
                )
            )
        }
        XCTAssertFalse(git.commands.contains { $0.contains("status") || $0.contains("pull") })
    }

    private func makeInstalledPackage(branch: String? = nil) throws -> PackageDefinition {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "#!/usr/bin/env bash\n".write(
            to: directory.appendingPathComponent("scripts/run-app.sh"),
            atomically: true,
            encoding: .utf8
        )

        return PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: branch,
            directoryURL: directory
        )
    }
}

private final class FakeGitRunner: GitRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private let remoteOutput: String
    private let currentBranchOutput: String
    private let statusOutput: String
    private let cloneHandler: (() throws -> Void)?

    init(
        remoteOutput: String = "https://github.com/sternard/Example-App.git",
        currentBranchOutput: String = "main",
        statusOutput: String,
        cloneHandler: (() throws -> Void)? = nil
    ) {
        self.remoteOutput = remoteOutput
        self.currentBranchOutput = currentBranchOutput
        self.statusOutput = statusOutput
        self.cloneHandler = cloneHandler
    }

    func run(_ arguments: [String], description: String) throws -> String {
        commands.append(arguments)
        if arguments.contains("remote") {
            return remoteOutput
        }
        if arguments.contains("branch") {
            return currentBranchOutput
        }
        if arguments.contains("status") {
            return statusOutput
        }
        if arguments.first == "clone" {
            try cloneHandler?()
        }
        return ""
    }
}
