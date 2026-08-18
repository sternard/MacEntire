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

    func testTerminatesDescendantProcessAfterTimeout() throws {
        let processIdentifierFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireChildPID-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIdentifierFile) }
        let runner = ProcessGitRunner(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            timeout: 0.1
        )

        XCTAssertThrowsError(try runner.run(
            [
                "-c",
                "/bin/sleep 30 & echo $! > \"$1\"; wait",
                "MacEntire timeout test",
                processIdentifierFile.path
            ],
            description: "Run process-tree test command"
        )) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .commandTimedOut(command: "Run process-tree test command")
            )
        }

        let processIdentifier = try XCTUnwrap(
            pid_t(String(contentsOf: processIdentifierFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(processIdentifier, 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
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
