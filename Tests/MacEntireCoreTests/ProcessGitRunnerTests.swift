import XCTest
@testable import MacEntireCore

final class ProcessGitRunnerTests: XCTestCase {
    func testTerminatesSubprocessAfterTimeout() {
        let runner = ProcessGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeout: 0.05
        )
        let start = Date()

        XCTAssertThrowsError(try runner.run(["5"], description: "Run test command")) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .commandTimedOut(command: "Run test command")
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
