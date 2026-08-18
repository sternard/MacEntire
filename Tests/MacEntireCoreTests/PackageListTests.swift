import XCTest
@testable import MacEntireCore

final class PackageListTests: XCTestCase {
    private let packagesDirectory = URL(fileURLWithPath: "/tmp/Packages", isDirectory: true)

    func testParsesURLsMarkdownBranchesAndComments() throws {
        let contents = """
        # Shared packages
        https://github.com/sternard/Storage-Assistant
        [HEIC converter](https://github.com/sternard/HEIC-to-JPEG.git) -b develop
        // Disabled in the shared catalog

        """

        let packages = try PackageListParser().parse(
            contents,
            packagesDirectory: packagesDirectory
        )

        XCTAssertEqual(packages.count, 2)
        XCTAssertEqual(packages[0].repositoryName, "Storage-Assistant")
        XCTAssertNil(packages[0].branch)
        XCTAssertEqual(packages[1].repositoryURL.absoluteString, "https://github.com/sternard/HEIC-to-JPEG")
        XCTAssertEqual(packages[1].branch, "develop")
    }

    func testRejectsInvalidBranch() {
        XCTAssertThrowsError(try PackageListParser().parse(
            "https://github.com/sternard/Storage-Assistant -b HEAD",
            packagesDirectory: packagesDirectory
        )) { error in
            XCTAssertEqual(
                error as? PackageListError,
                .invalidEntry(
                    line: 1,
                    value: "https://github.com/sternard/Storage-Assistant -b HEAD"
                )
            )
        }
    }

    func testRejectsDuplicateDestinationNames() {
        let contents = """
        https://github.com/sternard/Example-App
        https://github.com/someone-else/example-app
        """

        XCTAssertThrowsError(try PackageListParser().parse(
            contents,
            packagesDirectory: packagesDirectory
        )) { error in
            XCTAssertEqual(
                error as? PackageListError,
                .duplicateDirectory(line: 2, name: "example-app")
            )
        }
    }
}
