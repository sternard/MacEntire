import XCTest
@testable import MacEntireCore

final class PackageLauncherTests: XCTestCase {
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
