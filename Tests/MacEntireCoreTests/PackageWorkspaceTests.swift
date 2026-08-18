import XCTest
@testable import MacEntireCore

final class PackageWorkspaceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
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

    func testIgnoreListFiltersPackagesWithoutChangingSharedCatalog() throws {
        let workspace = PackageWorkspace(rootDirectory: temporaryRoot)
        try """
        https://github.com/sternard/Storage-Assistant
        https://github.com/sternard/Screen-Swap
        https://github.com/sternard/HEIC-to-JPEG
        """.write(to: workspace.packageListURL, atomically: true, encoding: .utf8)
        try """
        // This computer only has one display.
        https://github.com/sternard/Screen-Swap
        """.write(to: workspace.ignoreListURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try workspace.definitions().map(\.repositoryName),
            ["Storage-Assistant", "HEIC-to-JPEG"]
        )
    }

    func testMissingIgnoreListLeavesCatalogUnchanged() throws {
        let workspace = PackageWorkspace(rootDirectory: temporaryRoot)
        try """
        https://github.com/sternard/Storage-Assistant
        https://github.com/sternard/Screen-Swap
        """.write(to: workspace.packageListURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try workspace.definitions().count, 2)
    }

    func testIgnoreListDoesNotMatchAnotherOwnerWithTheSameRepositoryName() throws {
        let workspace = PackageWorkspace(rootDirectory: temporaryRoot)
        try "https://github.com/alice/Shared-Tool\n".write(
            to: workspace.packageListURL,
            atomically: true,
            encoding: .utf8
        )
        try "https://github.com/bob/Shared-Tool\n".write(
            to: workspace.ignoreListURL,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            try workspace.definitions().map(\.repositoryURL.absoluteString),
            ["https://github.com/alice/Shared-Tool"]
        )
    }

    func testWrongConfiguredBranchIsUnavailable() throws {
        let workspace = PackageWorkspace(rootDirectory: temporaryRoot)
        try "https://github.com/sternard/Example-App -b develop\n".write(
            to: workspace.packageListURL,
            atomically: true,
            encoding: .utf8
        )
        let checkout = workspace.packagesDirectory.appendingPathComponent(
            "Example-App",
            isDirectory: true
        )
        try makeCheckout(at: checkout)
        let git = WorkspaceGitRunner(branch: "main")

        let packages = try workspace.packages(gitRunner: git)

        XCTAssertEqual(packages.count, 1)
        guard case .unavailable(let reason) = packages[0].state else {
            return XCTFail("Expected unavailable package")
        }
        XCTAssertTrue(reason.contains("expected develop"))
    }

    private func makeCheckout(at directory: URL) throws {
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
    }
}

private struct WorkspaceGitRunner: GitRunning {
    let branch: String

    func run(_ arguments: [String], description: String) throws -> String {
        if arguments.contains("remote") {
            return "https://github.com/sternard/Example-App.git"
        }
        if arguments.contains("branch") {
            return branch
        }
        return ""
    }
}
