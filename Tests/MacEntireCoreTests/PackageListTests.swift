import XCTest
@testable import MacEntireCore

final class PackageListTests: XCTestCase {
    private let packagesDirectory = URL(fileURLWithPath: "/tmp/MacEntire/Packages", isDirectory: true)

    func testParsesPlainAndMarkdownGitHubURLsAndComments() throws {
        let contents = """
        // packages.txt
        https://github.com/sternard/Storage-Assistant

        [HEIC](https://github.com/sternard/HEIC-to-JPEG.git)
        # This is also a comment
        """

        let packages = try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)

        XCTAssertEqual(packages.map(\.repositoryName), ["Storage-Assistant", "HEIC-to-JPEG"])
        XCTAssertEqual(packages.map(\.displayName), ["Storage Assistant", "HEIC To JPEG"])
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

    func testRejectsDuplicateDestinationNames() {
        let contents = """
        https://github.com/first/Example-App
        https://github.com/second/example-app
        """

        XCTAssertThrowsError(try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)) { error in
            XCTAssertEqual(error as? PackageListError, .duplicateDirectory(line: 2, name: "example-app"))
        }
    }
}
