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

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages()

        XCTAssertEqual(packages.first?.state, .ready)
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
