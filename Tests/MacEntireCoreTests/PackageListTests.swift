import XCTest
@testable import MacEntireCore

final class PackageListTests: XCTestCase {
    private let packagesDirectory = URL(fileURLWithPath: "/tmp/MacEntire/Packages", isDirectory: true)

    func testParsesPlainAndMarkdownGitHubURLsAndComments() throws {
        let contents = """
        // packages.txt
        https://github.com/sternard/Storage-Assistant
        https://github.com/sternard/HEIC-to-JPEG.git -b develop
        [Screen Swap](https://github.com/sternard/Screen-Swap) -b feature/faster-swap
        # This is also a comment
        """

        let packages = try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)

        XCTAssertEqual(packages.map(\.repositoryName), ["Storage-Assistant", "HEIC-to-JPEG", "Screen-Swap"])
        XCTAssertEqual(packages.map(\.displayName), ["Storage Assistant", "HEIC To JPEG", "Screen Swap"])
        XCTAssertEqual(packages.map(\.branch), [nil, "develop", "feature/faster-swap"])
        XCTAssertEqual(
            packages[0].directoryURL,
            packagesDirectory.appendingPathComponent("Storage-Assistant", isDirectory: true)
        )
        XCTAssertEqual(packages[1].repositoryURL.absoluteString, "https://github.com/sternard/HEIC-to-JPEG")
    }

    func testRejectsNonGitHubURLs() {
        XCTAssertThrowsError(
            try PackageListParser().parse(
                "https://example.com/sternard/Storage-Assistant",
                packagesDirectory: packagesDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? PackageListError,
                .invalidEntry(line: 1, value: "https://example.com/sternard/Storage-Assistant")
            )
        }
    }

    func testRejectsIncompleteBranchOption() {
        let entry = "https://github.com/sternard/Storage-Assistant -b"

        XCTAssertThrowsError(
            try PackageListParser().parse(entry, packagesDirectory: packagesDirectory)
        ) { error in
            XCTAssertEqual(error as? PackageListError, .invalidEntry(line: 1, value: entry))
        }
    }

    func testRejectsHEADBranch() {
        let entry = "https://github.com/sternard/Storage-Assistant -b HEAD"

        XCTAssertThrowsError(
            try PackageListParser().parse(entry, packagesDirectory: packagesDirectory)
        ) { error in
            XCTAssertEqual(error as? PackageListError, .invalidEntry(line: 1, value: entry))
        }
    }

    func testRejectsFullyQualifiedRefsAsBranchOptions() {
        let entries = [
            "https://github.com/sternard/Storage-Assistant -b refs/heads/main",
            "https://github.com/sternard/Storage-Assistant -b refs/tags/release"
        ]

        for entry in entries {
            XCTAssertThrowsError(
                try PackageListParser().parse(entry, packagesDirectory: packagesDirectory)
            ) { error in
                XCTAssertEqual(error as? PackageListError, .invalidEntry(line: 1, value: entry))
            }
        }
    }

    func testRejectsPackageListFilenameAsDestination() {
        let entries = [
            "https://github.com/sternard/packages.txt",
            "https://github.com/sternard/packages.txt.git",
            "https://github.com/sternard/PACKAGES.TXT"
        ]

        for entry in entries {
            XCTAssertThrowsError(
                try PackageListParser().parse(entry, packagesDirectory: packagesDirectory)
            ) { error in
                XCTAssertEqual(error as? PackageListError, .invalidEntry(line: 1, value: entry))
            }
        }
    }

    func testRejectsTrackedMarkerFilenameAsDestination() {
        let entries = [
            "https://github.com/sternard/.gitkeep",
            "https://github.com/sternard/.gitkeep.git",
            "https://github.com/sternard/.GITKEEP"
        ]

        for entry in entries {
            XCTAssertThrowsError(
                try PackageListParser().parse(entry, packagesDirectory: packagesDirectory)
            ) { error in
                XCTAssertEqual(error as? PackageListError, .invalidEntry(line: 1, value: entry))
            }
        }
    }

    func testRejectsDuplicateDestinationNames() {
        let contents = """
        https://github.com/first/Example-App
        https://github.com/second/example-app
        """

        XCTAssertThrowsError(try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)) { error in
            XCTAssertEqual(error as? PackageListError, .duplicateDirectory(line: 2, name: "example-app"))
        }
    }

    func testCRLFRecordsUseLogicalLineNumbers() {
        let contents = [
            "https://github.com/first/Example-App",
            "# comment",
            "https://github.com/second/example-app"
        ].joined(separator: "\r\n")

        XCTAssertThrowsError(
            try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)
        ) { error in
            XCTAssertEqual(
                error as? PackageListError,
                .duplicateDirectory(line: 3, name: "example-app")
            )
        }
    }
}
