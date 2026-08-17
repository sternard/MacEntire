import XCTest
@testable import MacEntireCore

final class PackageWorkspaceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testReportsConfiguredPackageAsNotInstalled() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant")

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages()

        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages.first?.state, .notInstalled)
    }

    func testReadyPackageLaunchIsDisabledWhileSynchronizing() {
        let definition = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Storage-Assistant")!,
            repositoryName: "Storage-Assistant",
            displayName: "Storage Assistant",
            directoryURL: temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        )
        let package = ManagedPackage(definition: definition, state: .ready)

        XCTAssertTrue(package.isLaunchEnabled(whileSynchronizing: false))
        XCTAssertFalse(package.isLaunchEnabled(whileSynchronizing: true))
    }

    func testReportsRepositoryWithLauncherAsReady() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant")
        let repository = temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "#!/usr/bin/env bash\n".write(
            to: repository.appendingPathComponent("scripts/run-app.sh"),
            atomically: true,
            encoding: .utf8
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner()
        )

        XCTAssertEqual(packages.first?.state, .ready)
    }

    func testReportsRepositoryWithUnexpectedOriginAsUnavailable() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant")
        let repository = temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "#!/usr/bin/env bash\n".write(
            to: repository.appendingPathComponent("scripts/run-app.sh"),
            atomically: true,
            encoding: .utf8
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(
                remote: "https://github.com/someone-else/Storage-Assistant.git"
            )
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable(
                "Origin is https://github.com/someone-else/Storage-Assistant.git, "
                    + "expected https://github.com/sternard/Storage-Assistant."
            )
        )
    }

    func testReportsRepositoryOnWrongConfiguredBranchAsUnavailable() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant -b develop")
        let repository = temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "#!/usr/bin/env bash\n".write(
            to: repository.appendingPathComponent("scripts/run-app.sh"),
            atomically: true,
            encoding: .utf8
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(currentBranch: "main")
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("Storage-Assistant is on branch main, expected develop; update skipped.")
        )
    }

    func testReportsRepositoryWithoutLauncherAsUnavailable() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant")
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent("Packages/Storage-Assistant/.git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages()

        XCTAssertEqual(packages.first?.state, .unavailable("Missing scripts/run-app.sh"))
    }

    private func writePackageList(_ contents: String) throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try contents.write(
            to: packagesDirectory.appendingPathComponent("packages.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private struct WorkspaceGitRunner: GitRunning {
    let remote: String
    let currentBranch: String

    init(
        remote: String = "https://github.com/sternard/Storage-Assistant.git",
        currentBranch: String = "develop"
    ) {
        self.remote = remote
        self.currentBranch = currentBranch
    }

    func run(_ arguments: [String], description: String) throws -> String {
        if arguments.contains("branch") {
            return currentBranch
        }
        return remote
    }
}
