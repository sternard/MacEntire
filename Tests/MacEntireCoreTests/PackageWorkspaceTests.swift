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

    func testEmptyCatalogPreservesSynchronizationStatus() {
        XCTAssertEqual(
            refreshedPackageCatalogStatusMessage(
                currentMessage: "MacEntire updated — quit and run scripts/install-app.sh to install it",
                packagesAreEmpty: true
            ),
            "MacEntire updated — quit and run scripts/install-app.sh to install it"
        )
        XCTAssertEqual(
            refreshedPackageCatalogStatusMessage(
                currentMessage: "MacEntire: Update failed",
                packagesAreEmpty: true
            ),
            "MacEntire: Update failed"
        )
    }

    func testEmptyCatalogReportsNoPackagesWithoutOperationStatus() {
        XCTAssertEqual(
            refreshedPackageCatalogStatusMessage(
                currentMessage: nil,
                packagesAreEmpty: true
            ),
            "No packages configured"
        )
    }

    func testSuccessfulRefreshClearsPreviousInspectionError() {
        XCTAssertNil(refreshedPackageCatalogStatusMessage(
            currentMessage: "Could not read the package list",
            packagesAreEmpty: false,
            currentMessageIsInspectionError: true
        ))
        XCTAssertEqual(
            refreshedPackageCatalogStatusMessage(
                currentMessage: "Could not read the package list",
                packagesAreEmpty: true,
                currentMessageIsInspectionError: true
            ),
            "No packages configured"
        )
    }

    func testSuccessfulRefreshRestoresFallbackAfterInspectionError() {
        XCTAssertEqual(
            refreshedPackageCatalogStatusMessage(
                currentMessage: "Could not read the package list",
                packagesAreEmpty: false,
                currentMessageIsInspectionError: true,
                fallbackMessage: PendingReinstallationStore.statusMessage
            ),
            PendingReinstallationStore.statusMessage
        )
    }

    func testSuccessfulRefreshPreservesOperationStatus() {
        XCTAssertEqual(
            refreshedPackageCatalogStatusMessage(
                currentMessage: "MacEntire updated — quit and run scripts/install-app.sh to install it",
                packagesAreEmpty: false,
                currentMessageIsInspectionError: false
            ),
            "MacEntire updated — quit and run scripts/install-app.sh to install it"
        )
    }

    func testReadyPackageLaunchIsDisabledWhileSynchronizing() {
        let definition = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Storage-Assistant")!,
            repositoryName: "Storage-Assistant",
            displayName: "Storage Assistant",
            directoryURL: temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        )
        let package = ManagedPackage(definition: definition, state: .ready)

        XCTAssertTrue(package.isLaunchEnabled(
            whileSynchronizing: false,
            whilePackageIsLaunching: false
        ))
        XCTAssertFalse(package.isLaunchEnabled(
            whileSynchronizing: true,
            whilePackageIsLaunching: false
        ))
        XCTAssertFalse(package.isLaunchEnabled(
            whileSynchronizing: false,
            whilePackageIsLaunching: true
        ))
    }

    func testSynchronizationIsBlockedWhileLauncherIsActive() {
        var operations = PackageOperationState()

        XCTAssertTrue(operations.beginLaunch(packageIdentifier: "first"))
        XCTAssertFalse(operations.beginLaunch(packageIdentifier: "first"))
        XCTAssertTrue(operations.beginLaunch(packageIdentifier: "second"))
        XCTAssertTrue(operations.isLaunching(packageIdentifier: "first"))
        XCTAssertEqual(operations.activeLauncherCount, 2)
        XCTAssertFalse(operations.canSynchronize)
        XCTAssertFalse(operations.beginSynchronization())

        operations.endLaunch(packageIdentifier: "first")
        XCTAssertFalse(operations.canSynchronize)
        operations.endLaunch(packageIdentifier: "second")
        XCTAssertTrue(operations.beginSynchronization())
        XCTAssertFalse(operations.beginLaunch(packageIdentifier: "third"))
    }

    func testTerminationIsDeferredUntilSynchronizationEnds() {
        var termination = ApplicationTerminationState()
        termination.beginSynchronization()

        XCTAssertFalse(termination.requestTermination())
        XCTAssertTrue(termination.isTerminationDeferred)
        XCTAssertEqual(
            termination.endSynchronization(),
            .completeDeferredTermination
        )
        XCTAssertFalse(termination.isTerminationDeferred)
        XCTAssertFalse(termination.isSynchronizationInProgress)
    }

    func testDeferredTerminationCanBeCancelledWhenUpdateStateCannotBePersisted() {
        var termination = ApplicationTerminationState()
        termination.beginSynchronization()
        XCTAssertFalse(termination.requestTermination())

        XCTAssertEqual(
            termination.endSynchronization(allowDeferredTermination: false),
            .cancelDeferredTermination
        )
        XCTAssertFalse(termination.isTerminationDeferred)
        XCTAssertFalse(termination.isSynchronizationInProgress)
    }

    func testTerminationProceedsImmediatelyOutsideSynchronization() {
        var termination = ApplicationTerminationState()

        XCTAssertTrue(termination.requestTermination())
        XCTAssertFalse(termination.isTerminationDeferred)
    }

    func testPendingReinstallationReminderSurvivesDeferredTerminationCompletion() throws {
        let markerURL = temporaryRoot.appendingPathComponent("state/reinstall-required")
        let store = PendingReinstallationStore(markerURL: markerURL)
        let rootDirectory = temporaryRoot.appendingPathComponent("Checkout", isDirectory: true)
        var termination = ApplicationTerminationState()
        termination.beginSynchronization()
        XCTAssertFalse(termination.requestTermination())

        try store.markRequired(for: rootDirectory)
        XCTAssertEqual(
            termination.endSynchronization(),
            .completeDeferredTermination
        )

        let relaunchedStore = PendingReinstallationStore(markerURL: markerURL)
        XCTAssertEqual(
            relaunchedStore.statusMessage(for: rootDirectory),
            PendingReinstallationStore.statusMessage
        )
        XCTAssertNil(
            relaunchedStore.statusMessage(
                for: temporaryRoot.appendingPathComponent("DifferentCheckout", isDirectory: true)
            )
        )
        try relaunchedStore.clear()
        XCTAssertNil(relaunchedStore.statusMessage(for: rootDirectory))
    }

    func testUnavailablePackageDisplayTitleIncludesReason() {
        let definition = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Storage-Assistant")!,
            repositoryName: "Storage-Assistant",
            displayName: "Storage Assistant",
            directoryURL: temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        )
        let package = ManagedPackage(
            definition: definition,
            state: .unavailable("Missing scripts/run-app.sh")
        )

        XCTAssertEqual(
            package.displayTitle,
            "Storage Assistant — Unavailable: Missing scripts/run-app.sh"
        )
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
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner()
        )

        XCTAssertEqual(packages.first?.state, .ready)
    }

    func testReportsCredentialBearingOriginForConfiguredRepositoryAsReady() throws {
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
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(
                remote: "https://x-access-token:secret@github.com/sternard/Storage-Assistant.git"
            )
        )

        XCTAssertEqual(packages.first?.state, .ready)
    }

    func testReportsRewrittenTransportOriginAsReady() throws {
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
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(
                remote: "git@github.com:sternard/Storage-Assistant.git",
                rawRemote: "https://github.com/sternard/Storage-Assistant"
            )
        )

        XCTAssertEqual(packages.first?.state, .ready)
    }

    func testReportsNonExecutableLauncherAsUnavailable() throws {
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
        let launcher = repository.appendingPathComponent("scripts/run-app.sh")
        try "#!/usr/bin/env bash\n".write(to: launcher, atomically: true, encoding: .utf8)

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner()
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("Storage-Assistant scripts/run-app.sh is not executable.")
        )
    }

    func testReportsRepositoryWithUnexpectedOriginAsUnavailable() throws {
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
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(
                remote: "https://x-access-token:secret@github.com/someone-else/Storage-Assistant.git"
            )
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable(
                "Origin is https://github.com/someone-else/Storage-Assistant.git, "
                    + "expected https://github.com/sternard/Storage-Assistant."
            )
        )
    }

    func testReportsRepositoryResolvedToParentCheckoutAsUnavailable() throws {
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
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(topLevel: temporaryRoot.path)
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("Storage-Assistant already exists but is not a Git repository.")
        )
    }

    func testReportsRepositoryUnderSymlinkedWorkspaceAncestorAsReady() throws {
        let physicalRoot = temporaryRoot.appendingPathComponent("PhysicalRoot", isDirectory: true)
        let linkedRoot = temporaryRoot.appendingPathComponent("LinkedRoot", isDirectory: true)
        let packagesDirectory = physicalRoot.appendingPathComponent("Packages", isDirectory: true)
        let repository = packagesDirectory.appendingPathComponent("Storage-Assistant", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )
        try "https://github.com/sternard/Storage-Assistant".write(
            to: packagesDirectory.appendingPathComponent("packages.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: physicalRoot)

        let packages = try PackageWorkspace(rootDirectory: linkedRoot).packages(
            gitRunner: WorkspaceGitRunner(topLevel: repository.path)
        )

        XCTAssertEqual(packages.first?.state, .ready)
    }

    func testReportsSymlinkedCheckoutDirectoryAsUnavailable() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant")
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let externalDirectory = temporaryRoot.appendingPathComponent("External-Storage-Assistant", isDirectory: true)
        let checkoutDirectory = packagesDirectory.appendingPathComponent("Storage-Assistant", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalDirectory.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeExecutableWorkspaceLauncher(
            at: externalDirectory.appendingPathComponent("scripts/run-app.sh")
        )
        try FileManager.default.createSymbolicLink(at: checkoutDirectory, withDestinationURL: externalDirectory)

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner()
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("Storage-Assistant checkout path is a symbolic link.")
        )
    }

    func testReportsPackagesUnderSymlinkedDirectoryAsUnavailable() throws {
        let externalPackagesDirectory = temporaryRoot.appendingPathComponent(
            "External-Packages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalPackagesDirectory,
            withIntermediateDirectories: true
        )
        try "https://github.com/sternard/Storage-Assistant".write(
            to: externalPackagesDirectory.appendingPathComponent("packages.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: temporaryRoot.appendingPathComponent("Packages", isDirectory: true),
            withDestinationURL: externalPackagesDirectory
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages()

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("The Packages directory is a symbolic link.")
        )
    }

    func testReportsRepositoryOnWrongConfiguredBranchAsUnavailable() throws {
        try writePackageList("https://github.com/sternard/Storage-Assistant -b develop")
        let repository = temporaryRoot.appendingPathComponent("Packages/Storage-Assistant", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(currentBranch: "main")
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("Storage-Assistant is on branch main, expected develop; update skipped.")
        )
    }

    func testReportsDetachedRepositoryWithoutConfiguredBranchAsUnavailable() throws {
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
        try writeExecutableWorkspaceLauncher(
            at: repository.appendingPathComponent("scripts/run-app.sh")
        )

        let packages = try PackageWorkspace(rootDirectory: temporaryRoot).packages(
            gitRunner: WorkspaceGitRunner(currentBranch: "")
        )

        XCTAssertEqual(
            packages.first?.state,
            .unavailable("Storage-Assistant has a detached HEAD; update skipped.")
        )
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

private func writeExecutableWorkspaceLauncher(at url: URL) throws {
    try "#!/usr/bin/env bash\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private struct WorkspaceGitRunner: GitRunning {
    let remote: String
    let rawRemote: String?
    let topLevel: String?
    let currentBranch: String

    init(
        remote: String = "https://github.com/sternard/Storage-Assistant.git",
        rawRemote: String? = nil,
        topLevel: String? = nil,
        currentBranch: String = "develop"
    ) {
        self.remote = remote
        self.rawRemote = rawRemote
        self.topLevel = topLevel
        self.currentBranch = currentBranch
    }

    func run(_ arguments: [String], description: String) throws -> String {
        if arguments.contains("rev-parse") {
            return topLevel ?? arguments[1]
        }
        if arguments.contains("branch") {
            return currentBranch
        }
        if arguments.suffix(3) == ["config", "--get", "remote.origin.url"] {
            return rawRemote ?? remote
        }
        return remote
    }
}
