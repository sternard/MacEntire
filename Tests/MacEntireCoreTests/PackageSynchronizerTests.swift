import XCTest
@testable import MacEntireCore

final class PackageSynchronizerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("Packages", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testSelfUpdateReloadsNewCatalogBeforeSynchronizingPackages() throws {
        let workspace = PackageWorkspace(rootDirectory: temporaryRoot)
        try "".write(to: workspace.packageListURL, atomically: true, encoding: .utf8)
        var headReads = 0
        let git = RecordingGitRunner { [temporaryRoot] arguments, _ in
            if arguments.contains("--show-toplevel") {
                return temporaryRoot!.path
            }
            if arguments.contains("status") {
                return ""
            }
            if arguments.contains("branch") {
                return "main"
            }
            if arguments.suffix(2) == ["rev-parse", "HEAD"] {
                headReads += 1
                return headReads < 3 ? "old-revision" : "new-revision"
            }
            if arguments.contains("merge"), arguments.contains(temporaryRoot!.path) {
                try "https://github.com/sternard/New-App\n".write(
                    to: workspace.packageListURL,
                    atomically: true,
                    encoding: .utf8
                )
                return ""
            }
            if arguments.first == "clone", let destination = arguments.last {
                try self.makeLauncher(at: URL(fileURLWithPath: destination, isDirectory: true))
            }
            return ""
        }
        let synchronizer = PackageSynchronizer(workspace: workspace, gitRunner: git)

        let summary = synchronizer.synchronizeAll()

        XCTAssertTrue(summary.macEntireUpdated)
        XCTAssertEqual(summary.packageResults.map(\.package.repositoryName), ["New-App"])
        XCTAssertTrue(summary.packageResults.allSatisfy(\.succeeded))
        let updateIndex = try XCTUnwrap(git.commands.firstIndex {
            $0.contains("merge") && $0.contains(temporaryRoot.path)
        })
        let cloneIndex = try XCTUnwrap(git.commands.firstIndex { $0.first == "clone" })
        XCTAssertLessThan(updateIndex, cloneIndex)
    }

    func testRealSelfUpdateAddsCatalogEntryAndPreservesLocalIgnoreList() throws {
        let integrationRoot = temporaryRoot.appendingPathComponent(
            "SelfUpdateIntegration",
            isDirectory: true
        )
        let upstream = integrationRoot.appendingPathComponent("upstream", isDirectory: true)
        let origin = integrationRoot.appendingPathComponent("origin.git", isDirectory: true)
        let checkout = integrationRoot.appendingPathComponent("checkout", isDirectory: true)
        let upstreamPackages = upstream.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: upstreamPackages,
            withIntermediateDirectories: true
        )
        try """
        Packages/*
        !Packages/packages.txt
        """.write(
            to: upstream.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        let upstreamPackageList = upstreamPackages.appendingPathComponent("packages.txt")
        try "https://github.com/sternard/Screen-Swap\n".write(
            to: upstreamPackageList,
            atomically: true,
            encoding: .utf8
        )

        try runGit(["init", "-b", "main", upstream.path])
        try runGit(["-C", upstream.path, "add", "."])
        try runGit([
            "-C", upstream.path,
            "-c", "user.name=MacEntire Tests",
            "-c", "user.email=tests@example.com",
            "commit", "-m", "Initial catalog"
        ])
        try runGit(["clone", "--bare", upstream.path, origin.path])
        try runGit(["clone", origin.path, checkout.path])
        try runGit(["-C", upstream.path, "remote", "add", "origin", origin.path])

        let workspace = PackageWorkspace(rootDirectory: checkout)
        let ignoredContents = "https://github.com/sternard/Screen-Swap\n"
        try ignoredContents.write(
            to: workspace.ignoreListURL,
            atomically: true,
            encoding: .utf8
        )
        try """
        https://github.com/sternard/Screen-Swap
        https://github.com/sternard/New-App
        """.write(to: upstreamPackageList, atomically: true, encoding: .utf8)
        try runGit(["-C", upstream.path, "add", "Packages/packages.txt"])
        try runGit([
            "-C", upstream.path,
            "-c", "user.name=MacEntire Tests",
            "-c", "user.email=tests@example.com",
            "commit", "-m", "Add new package"
        ])
        try runGit(["-C", upstream.path, "push", "origin", "main"])

        let synchronizer = PackageSynchronizer(workspace: workspace)

        XCTAssertTrue(try synchronizer.synchronizeMacEntire())
        XCTAssertEqual(
            try workspace.definitions().map(\.repositoryName),
            ["New-App"]
        )
        XCTAssertEqual(
            try String(contentsOf: workspace.ignoreListURL, encoding: .utf8),
            ignoredContents
        )
    }

    func testDirtyMacEntireSkipsSelfUpdateButStillSynchronizesPackages() throws {
        let workspace = PackageWorkspace(rootDirectory: temporaryRoot)
        try "https://github.com/sternard/Example-App\n".write(
            to: workspace.packageListURL,
            atomically: true,
            encoding: .utf8
        )
        let package = try makeInstalledPackage()
        let git = RecordingGitRunner { [temporaryRoot] arguments, _ in
            if arguments.contains("--show-toplevel") {
                return temporaryRoot!.path
            }
            if arguments.contains("status") {
                return arguments.contains(temporaryRoot!.path) ? " M README.md" : ""
            }
            if arguments.contains("remote") {
                return package.repositoryURL.absoluteString
            }
            if arguments.contains("branch") {
                return "main"
            }
            return ""
        }
        let synchronizer = PackageSynchronizer(workspace: workspace, gitRunner: git)

        let summary = synchronizer.synchronizeAll()

        XCTAssertFalse(summary.macEntireUpdated)
        XCTAssertTrue(summary.macEntireErrorMessage?.contains("local changes") == true)
        XCTAssertEqual(summary.packageResults.count, 1)
        XCTAssertTrue(summary.packageResults[0].succeeded)
        XCTAssertTrue(git.commands.contains {
            $0.contains("fetch") && $0.contains(package.directoryURL.path)
        })
        XCTAssertFalse(git.commands.contains {
            $0.contains("fetch") && $0.contains(temporaryRoot.path)
        })
    }

    func testConfiguredBranchFetchesExplicitRefAndMergesSafely() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = RecordingGitRunner { arguments, _ in
            if arguments.contains("remote") {
                return package.repositoryURL.absoluteString + ".git"
            }
            if arguments.contains("branch") {
                return "develop"
            }
            return ""
        }
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
    }

    func testRefusesPackageWithLocalChanges() throws {
        let package = try makeInstalledPackage()
        let git = RecordingGitRunner { arguments, _ in
            if arguments.contains("remote") {
                return package.repositoryURL.absoluteString
            }
            if arguments.contains("status") {
                return " M README.md"
            }
            return "main"
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .localChanges("Example-App"))
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") })
    }

    func testMissingRepositoryClonesConfiguredBranch() throws {
        let directory = temporaryRoot.appendingPathComponent(
            "Packages/Example-App",
            isDirectory: true
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: "release/next",
            directoryURL: directory
        )
        let git = RecordingGitRunner { arguments, _ in
            if arguments.first == "clone" {
                try self.makeLauncher(at: directory)
            }
            return ""
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertEqual(git.commands, [
            [
                "ls-remote", "--exit-code", "--heads",
                package.repositoryURL.absoluteString,
                "refs/heads/release/next"
            ],
            [
                "clone", "--origin", "origin", "--branch", "release/next", "--single-branch",
                package.repositoryURL.absoluteString, directory.path
            ]
        ])
    }

    func testMissingRepositoryRejectsConfiguredTagBeforeCloning() throws {
        let directory = temporaryRoot.appendingPathComponent(
            "Packages/Example-App",
            isDirectory: true
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: "release",
            directoryURL: directory
        )
        let missingBranch = PackageSyncError.commandFailed(
            command: "Find Example-App branch",
            output: "No matching branch"
        )
        let git = RecordingGitRunner { arguments, _ in
            if arguments.first == "ls-remote" {
                throw missingBranch
            }
            return ""
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, missingBranch)
        }
        XCTAssertFalse(git.commands.contains { $0.first == "clone" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRemoteMismatchRedactsCredentials() throws {
        let package = try makeInstalledPackage()
        let git = RecordingGitRunner { arguments, _ in
            if arguments.contains("remote") {
                return "https://secret@github.com/someone-else/Example-App?token=hidden"
            }
            return ""
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("secret"))
            XCTAssertFalse(message.contains("hidden"))
        }
    }

    private func makeInstalledPackage(branch: String? = nil) throws -> PackageDefinition {
        let directory = temporaryRoot.appendingPathComponent(
            "Packages/Example-App",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try makeLauncher(at: directory)

        return PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: branch,
            directoryURL: directory
        )
    }

    private func makeLauncher(at directory: URL) throws {
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

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        try ProcessGitRunner().run(arguments, description: "Test Git")
    }
}

private final class RecordingGitRunner: GitRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private let handler: ([String], String) throws -> String

    init(handler: @escaping ([String], String) throws -> String) {
        self.handler = handler
    }

    func run(_ arguments: [String], description: String) throws -> String {
        commands.append(arguments)
        return try handler(arguments, description)
    }
}
