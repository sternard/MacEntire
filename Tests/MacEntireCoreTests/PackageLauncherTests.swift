import XCTest
@testable import MacEntireCore

final class PackageLauncherTests: XCTestCase {
    func testSuccessfulLaunchCompletionClearsStatusMessage() {
        XCTAssertNil(packageLaunchCompletionMessage(for: .success(())))
    }

    func testFailedLaunchCompletionPreservesErrorMessage() {
        let error = PackageLaunchError.unsuccessfulExit(
            package: "Example App",
            status: 7,
            output: "required tool is missing"
        )

        XCTAssertEqual(
            packageLaunchCompletionMessage(for: .failure(error)),
            "Example App launcher exited with status 7: required tool is missing"
        )
    }

    func testSuccessfulCompletionPreservesAnotherActiveLaunchStatus() {
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        var status = PackageLaunchStatusState()
        status.beginLaunch(packageIdentifier: "first", packageName: "First App", identifier: firstIdentifier)
        status.beginLaunch(packageIdentifier: "second", packageName: "Second App", identifier: secondIdentifier)

        status.completeLaunch(identifier: secondIdentifier, result: .success(()))

        XCTAssertEqual(status.message, "Launching First App…")
    }

    func testSuccessfulCompletionDoesNotEraseAnotherLaunchFailure() {
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        var status = PackageLaunchStatusState()
        status.beginLaunch(packageIdentifier: "first", packageName: "First App", identifier: firstIdentifier)
        status.beginLaunch(packageIdentifier: "second", packageName: "Second App", identifier: secondIdentifier)
        status.completeLaunch(
            identifier: secondIdentifier,
            result: .failure(.unsuccessfulExit(package: "Second App", status: 7, output: "failed"))
        )

        status.completeLaunch(identifier: firstIdentifier, result: .success(()))

        XCTAssertEqual(status.message, "Second App launcher exited with status 7: failed")
    }

    func testSuccessfulRetryClearsPreviousFailureForSamePackage() {
        let failedIdentifier = UUID()
        let retryIdentifier = UUID()
        var status = PackageLaunchStatusState()
        status.beginLaunch(packageIdentifier: "example", packageName: "Example App", identifier: failedIdentifier)
        status.completeLaunch(
            identifier: failedIdentifier,
            result: .failure(.unsuccessfulExit(package: "Example App", status: 7, output: "failed"))
        )
        XCTAssertEqual(status.message, "Example App launcher exited with status 7: failed")

        status.beginLaunch(packageIdentifier: "example", packageName: "Example App", identifier: retryIdentifier)
        status.completeLaunch(identifier: retryIdentifier, result: .success(()))

        XCTAssertNil(status.message)
    }

    func testSupersededLaunchCompletionCannotRestoreStaleFailure() {
        let firstIdentifier = UUID()
        let retryIdentifier = UUID()
        var status = PackageLaunchStatusState()
        status.beginLaunch(packageIdentifier: "example", packageName: "Example App", identifier: firstIdentifier)
        status.beginLaunch(packageIdentifier: "example", packageName: "Example App", identifier: retryIdentifier)

        status.completeLaunch(
            identifier: firstIdentifier,
            result: .failure(.unsuccessfulExit(package: "Example App", status: 7, output: "stale"))
        )
        status.completeLaunch(identifier: retryIdentifier, result: .success(()))

        XCTAssertNil(status.message)
    }

    func testDistinctPackagesWithSameDisplayNameKeepIndependentStatus() {
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        var status = PackageLaunchStatusState()
        status.beginLaunch(
            packageIdentifier: "https://github.com/sternard/foo-bar",
            packageName: "Foo Bar",
            identifier: firstIdentifier
        )
        status.beginLaunch(
            packageIdentifier: "https://github.com/sternard/foo_bar",
            packageName: "Foo Bar",
            identifier: secondIdentifier
        )

        status.completeLaunch(
            identifier: firstIdentifier,
            result: .failure(.unsuccessfulExit(package: "Foo Bar", status: 7, output: "failed"))
        )
        status.completeLaunch(identifier: secondIdentifier, result: .success(()))

        XCTAssertEqual(status.message, "Foo Bar launcher exited with status 7: failed")
    }

    func testReportsNonzeroLauncherExitWithCapturedOutput() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireLauncherTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let scriptsDirectory = temporaryRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let launcherURL = scriptsDirectory.appendingPathComponent("run-app.sh", isDirectory: false)
        try "echo 'required tool is missing' >&2\nexit 7\n".write(
            to: launcherURL,
            atomically: true,
            encoding: .utf8
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: temporaryRoot
        )
        let completionExpectation = expectation(description: "Launcher completion")
        let launchError = LockedBox<PackageLaunchError?>(nil)
        let launcher = PackageLauncher()

        try launcher.launch(package) { result in
            if case .failure(let error) = result {
                launchError.set(error)
            }
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2)
        XCTAssertEqual(
            launchError.get(),
            .unsuccessfulExit(package: "Example App", status: 7, output: "required tool is missing")
        )
    }

    func testDrainsFinalDiagnosticBeforeReportingFailure() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireLauncherTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let scriptsDirectory = temporaryRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let launcherURL = scriptsDirectory.appendingPathComponent("run-app.sh", isDirectory: false)
        try "printf 'FINAL-DIAGNOSTIC' >&2\nexit 9\n".write(
            to: launcherURL,
            atomically: true,
            encoding: .utf8
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: temporaryRoot
        )
        let completionExpectation = expectation(description: "Launcher completion")
        let launchError = LockedBox<PackageLaunchError?>(nil)
        let launcher = PackageLauncher()

        try launcher.launch(package) { result in
            if case .failure(let error) = result {
                launchError.set(error)
            }
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2)
        XCTAssertEqual(
            launchError.get(),
            .unsuccessfulExit(package: "Example App", status: 9, output: "FINAL-DIAGNOSTIC")
        )
    }

    func testCapturesOnlyBoundedTailOfLauncherOutput() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireLauncherTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let scriptsDirectory = temporaryRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let launcherURL = scriptsDirectory.appendingPathComponent("run-app.sh", isDirectory: false)
        try """
        /usr/bin/yes x | /usr/bin/head -c 70000
        printf '\nTAIL-MARKER\n' >&2
        exit 7
        """.write(to: launcherURL, atomically: true, encoding: .utf8)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: temporaryRoot
        )
        let completionExpectation = expectation(description: "Launcher completion")
        let launchError = LockedBox<PackageLaunchError?>(nil)
        let launcher = PackageLauncher()

        try launcher.launch(package) { result in
            if case .failure(let error) = result {
                launchError.set(error)
            }
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2)
        guard case .unsuccessfulExit(_, let status, let output) = launchError.get() else {
            return XCTFail("Expected a failed launcher result")
        }
        XCTAssertEqual(status, 7)
        XCTAssertTrue(output.hasSuffix("TAIL-MARKER"))
        XCTAssertLessThanOrEqual(output.utf8.count, PackageLauncher.maximumCapturedOutputBytes)
    }

    func testCompletionDoesNotWaitForBackgroundDescendantsToCloseOutput() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireLauncherTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let scriptsDirectory = temporaryRoot.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let launcherURL = scriptsDirectory.appendingPathComponent("run-app.sh", isDirectory: false)
        try "/bin/sleep 2 &\nexit 0\n".write(
            to: launcherURL,
            atomically: true,
            encoding: .utf8
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: temporaryRoot
        )
        let completionExpectation = expectation(description: "Launcher completion")
        let start = Date()
        let launcher = PackageLauncher()

        try launcher.launch(package) { _ in
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(launcher.activeOutputCaptureCount, 0)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
