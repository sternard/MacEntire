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

    func testCapturesOnlyBoundedTailWhileCommandRuns() {
        let runner = ProcessGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 2
        )
        var capturedOutput = ""

        XCTAssertThrowsError(try runner.run(
            ["-c", "/usr/bin/yes x | /usr/bin/head -c 300000; printf '\\nTAIL-MARKER\\n' >&2; exit 7"],
            description: "Run verbose command"
        )) { error in
            guard case .commandFailed(_, let output) = error as? PackageSyncError else {
                return XCTFail("Expected a failed command result")
            }
            capturedOutput = output
        }

        XCTAssertTrue(capturedOutput.hasSuffix("TAIL-MARKER"))
        XCTAssertLessThanOrEqual(
            capturedOutput.utf8.count,
            ProcessGitRunner.maximumCapturedOutputBytes
        )
    }
}
