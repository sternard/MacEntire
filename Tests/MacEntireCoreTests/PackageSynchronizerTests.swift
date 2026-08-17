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

    func testRefusesToUpdateRepositoryWithLocalChanges() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(statusOutput: " M README.md")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .localChanges("Example-App"))
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testCleanRepositoryFetchesCurrentBranchFromOriginAndFastForwardsSafely() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains {
            $0.suffix(3) == ["fetch", "origin", "refs/heads/main"]
        })
        XCTAssertTrue(git.commands.contains {
            $0.suffix(4) == ["merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"]
        })
        XCTAssertFalse(git.commands.contains { $0.contains("pull") })
    }

    func testConfiguredBranchFetchesExplicitlyFromOriginAndFastForwardsSafely() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = FakeGitRunner(currentBranchOutput: "develop", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains {
            $0.suffix(3) == ["fetch", "origin", "refs/heads/develop"]
        })
        XCTAssertTrue(git.commands.contains {
            $0.suffix(4) == ["merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"]
        })
        XCTAssertFalse(git.commands.contains { $0.contains("pull") })
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
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testRefusesDetachedHead() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(currentBranchOutput: "", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .detachedHead("Example-App"))
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
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
        let git = FakeGitRunner(currentBranchOutput: "release/next", statusOutput: "") {
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

        XCTAssertEqual(git.commands, [
            [
                "clone", "--origin", "origin", "--branch", "release/next", "--single-branch",
                "https://github.com/sternard/Example-App", directory.path
            ],
            ["-C", directory.path, "branch", "--show-current"]
        ])
    }

    func testRefusesConfiguredBranchCloneThatLandsOnDetachedHead() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: "release",
            directoryURL: directory
        )
        let git = FakeGitRunner(currentBranchOutput: "", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .detachedHead("Example-App"))
        }
        XCTAssertEqual(git.commands, [
            [
                "clone", "--origin", "origin", "--branch", "release", "--single-branch",
                "https://github.com/sternard/Example-App", directory.path
            ],
            ["-C", directory.path, "branch", "--show-current"]
        ])
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
        XCTAssertFalse(git.commands.contains {
            $0.contains("status") || $0.contains("fetch") || $0.contains("merge")
        })
    }

    func testRefusesLauncherDirectory() throws {
        let package = try makeInstalledPackage()
        try FileManager.default.removeItem(at: package.launcherURL)
        try FileManager.default.createDirectory(at: package.launcherURL, withIntermediateDirectories: false)
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: FakeGitRunner(statusOutput: "")
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .missingLauncher("Example-App"))
        }
    }

    func testRefusesLauncherSymlinkToDirectory() throws {
        let package = try makeInstalledPackage()
        try FileManager.default.removeItem(at: package.launcherURL)
        let launcherDirectory = package.directoryURL.appendingPathComponent("LauncherDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: package.launcherURL, withDestinationURL: launcherDirectory)
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: FakeGitRunner(statusOutput: "")
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .missingLauncher("Example-App"))
        }
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
