import Darwin
import XCTest
@testable import MacEntireCore

final class PackageSynchronizerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testStableDirectoryHandlesAreClosedWhenLaunchingProcesses() throws {
        let descriptor = open(temporaryRoot.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)

        let handle = try StableDirectoryHandle(descriptor: descriptor)
        let descriptorFlags = fcntl(handle.descriptor, F_GETFD)

        XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
        XCTAssertEqual(descriptorFlags & FD_CLOEXEC, FD_CLOEXEC)
        withExtendedLifetime(handle) {}
    }

    func testMacEntireUpdatePullsAndRestoresCustomizedPackageList() throws {
        let packageList = try writePackageList("custom package list\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        let requiresReinstallation = try synchronizer.synchronizeMacEntire()

        XCTAssertTrue(requiresReinstallation)
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
        let commands = git.commands.map { arguments in
            var normalized = arguments
            if let workingDirectoryIndex = normalized.firstIndex(of: "-C") {
                normalized[workingDirectoryIndex + 1] = temporaryRoot.path
            }
            return normalized
        }
        XCTAssertEqual(commands, [
            ["-C", temporaryRoot.path, "rev-parse", "--show-toplevel"],
            ["-C", temporaryRoot.path, "branch", "--show-current"],
            ["-C", temporaryRoot.path, "rev-parse", "HEAD"],
            ["-C", temporaryRoot.path, "rev-parse", "--git-path", "index"],
            ["-C", temporaryRoot.path, "ls-files", "--stage", "--", "Packages/packages.txt"],
            ["-C", temporaryRoot.path, "ls-tree", "HEAD", "--", "Packages/packages.txt"],
            [
                "-C", temporaryRoot.path,
                "restore", "--source=HEAD", "--staged", "--worktree", "--", "Packages/packages.txt"
            ],
            ["-C", temporaryRoot.path, "fetch"],
            ["-C", temporaryRoot.path, "branch", "--show-current"],
            ["-C", temporaryRoot.path, "rev-parse", "HEAD"],
            ["-C", temporaryRoot.path, "merge", "--ff-only", "--no-overwrite-ignore", "main@{upstream}"],
            ["-C", temporaryRoot.path, "rev-parse", "HEAD"],
            [
                "--no-optional-locks", "-C", temporaryRoot.path,
                "status", "--porcelain", "--", "Packages/packages.txt"
            ],
            ["-C", temporaryRoot.path, "ls-files", "--stage", "--", "Packages/packages.txt"],
            ["-C", temporaryRoot.path, "ls-tree", "HEAD", "--", "Packages/packages.txt"]
        ])
    }

    func testMacEntireUpdatePreservesManifestEditMadeDuringUpdate() throws {
        let packageList = try writePackageList("custom package list\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            packageListEditDuringUpdate: "newer user edit\n"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronizeMacEntire()

        XCTAssertEqual(try String(contentsOf: packageList), "newer user edit\n")
    }

    func testMacEntireUpdatePreservesManifestEditMadeAfterConcurrentEditCheck() throws {
        let packageList = try writePackageList("custom package list\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            packageListEditAfterStatusCheck: "newer user edit\n"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronizeMacEntire()

        XCTAssertEqual(try String(contentsOf: packageList), "newer user edit\n")
    }

    func testMacEntireUpdatePreservesNewBranchManifestWhenBranchChangesDuringFetch() throws {
        let packageList = try writePackageList("original branch customization\n")
        let stagedObjectID = String(repeating: "1", count: 40)
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            indexEntryOutput: "100644 \(stagedObjectID) 0\tPackages/packages.txt",
            headEntryOutput: "100644 blob \(String(repeating: "0", count: 40))\tPackages/packages.txt",
            currentBranchOutput: "main",
            currentBranchOutputAfterFetch: "develop",
            packageListEditDuringFetch: "develop branch package list\n"
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronizeMacEntire()
        ) { error in
            guard case .packageListRecoveryRequired(let reason, let location) = error as? PackageSyncError else {
                return XCTFail("Expected a package-list recovery error")
            }
            XCTAssertEqual(
                reason,
                PackageSyncError.branchMismatch(
                    repository: "MacEntire",
                    expected: "main",
                    actual: "develop"
                ).localizedDescription
            )
            let recoveryDirectory = URL(fileURLWithPath: location, isDirectory: true)
            XCTAssertEqual(
                try? Data(contentsOf: recoveryDirectory.appendingPathComponent("packages.txt.worktree")),
                Data("original branch customization\n".utf8)
            )
            let indexRecovery = try? String(
                contentsOf: recoveryDirectory.appendingPathComponent("packages.txt.index"),
                encoding: .utf8
            )
            XCTAssertTrue(indexRecovery?.contains(stagedObjectID) == true)
        }

        XCTAssertEqual(try String(contentsOf: packageList), "develop branch package list\n")
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
        XCTAssertTrue(git.commands.contains { arguments in
            arguments.contains("update-ref")
                && arguments.contains(stagedObjectID)
                && arguments.contains { $0.hasPrefix("refs/macentire-recovery/") }
        })
    }

    func testMacEntireUpdatePreservesCheckoutStateWhenFetchFailsAfterBranchChange() throws {
        let packageList = try writePackageList("original branch customization\n")
        let fetchError = PackageSyncError.commandFailed(
            command: "Fetch MacEntire",
            output: "network unavailable"
        )
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            fetchError: fetchError,
            currentBranchOutputAfterFetch: "develop",
            packageListEditDuringFetch: "new branch package list\n"
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronizeMacEntire()
        ) { error in
            guard case .packageListRecoveryRequired(let reason, let location) =
                error as? PackageSyncError
            else {
                return XCTFail("Expected a package-list recovery error")
            }
            XCTAssertEqual(reason, fetchError.localizedDescription)
            XCTAssertEqual(
                try? Data(
                    contentsOf: URL(fileURLWithPath: location, isDirectory: true)
                        .appendingPathComponent("packages.txt.worktree")
                ),
                Data("original branch customization\n".utf8)
            )
        }

        XCTAssertEqual(try String(contentsOf: packageList), "new branch package list\n")
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testMacEntireUpdateRestoresManifestWhenFetchFailsWithoutCheckoutChange() throws {
        let packageList = try writePackageList("custom package list\n")
        let fetchError = PackageSyncError.commandFailed(
            command: "Fetch MacEntire",
            output: "network unavailable"
        )
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            fetchError: fetchError
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronizeMacEntire()
        ) { error in
            XCTAssertEqual(error as? PackageSyncError, fetchError)
        }

        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testMacEntireUpdatePreservesNewManifestWhenHeadChangesDuringFetch() throws {
        let packageList = try writePackageList("original customization\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            revisionAfterFetch: "user-commit",
            packageListEditDuringFetch: "new committed package list\n"
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronizeMacEntire()
        ) { error in
            guard case .packageListRecoveryRequired(let reason, let location) = error as? PackageSyncError else {
                return XCTFail("Expected a package-list recovery error")
            }
            XCTAssertEqual(reason, PackageSyncError.localChanges("MacEntire").localizedDescription)
            XCTAssertEqual(
                try? Data(
                    contentsOf: URL(fileURLWithPath: location, isDirectory: true)
                        .appendingPathComponent("packages.txt.worktree")
                ),
                Data("original customization\n".utf8)
            )
        }

        XCTAssertEqual(try String(contentsOf: packageList), "new committed package list\n")
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testMacEntireUpdateRestoresManifestWhenEditDetectionFails() throws {
        let packageList = try writePackageList("custom package list\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            statusError: .commandFailed(command: "Inspect package list", output: "status failed")
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronizeMacEntire()) { error in
            guard case .packageListRestorationFailed = error as? PackageSyncError else {
                return XCTFail("Expected a package-list restoration failure")
            }
        }
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
    }

    func testMacEntireUpdateRejectsReplacedPackagesDirectoryBeforeManifestRestore() throws {
        let packageList = try writePackageList("custom package list\n")
        let externalPackagesDirectory = temporaryRoot.appendingPathComponent(
            "External-Packages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalPackagesDirectory,
            withIntermediateDirectories: true
        )
        let externalPackageList = externalPackagesDirectory.appendingPathComponent("packages.txt")
        try "external package list\n".write(
            to: externalPackageList,
            atomically: true,
            encoding: .utf8
        )
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            packagesDirectoryReplacementDuringStatus: externalPackagesDirectory
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronizeMacEntire()
        ) { error in
            guard case .packageListRestorationFailed(let detail, let requiresReinstallation) =
                error as? PackageSyncError
            else {
                return XCTFail("Expected a package-list restoration failure")
            }
            XCTAssertTrue(detail.contains("The Packages directory is a symbolic link."))
            XCTAssertTrue(requiresReinstallation)
        }

        XCTAssertEqual(try String(contentsOf: externalPackageList), "external package list\n")
        XCTAssertEqual(
            try String(
                contentsOf: temporaryRoot.appendingPathComponent(
                    "Original-Packages/packages.txt"
                )
            ),
            "upstream package list\n"
        )
    }

    func testMacEntireUpdateDoesNotMergeAfterRootIsReplacedDuringFetch() throws {
        let packageList = try writePackageList("custom package list\n")
        let movedRoot = temporaryRoot.deletingLastPathComponent().appendingPathComponent(
            "Moved-MacEntire-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: movedRoot) }
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            rootDirectoryMoveDestinationDuringFetch: movedRoot
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronizeMacEntire()
        ) { error in
            guard case .packageListRecoveryRequired(let reason, let location) =
                error as? PackageSyncError
            else {
                return XCTFail("Expected a package-list recovery error")
            }
            XCTAssertEqual(reason, PackageSyncError.macEntireCheckoutChanged.localizedDescription)
            XCTAssertEqual(
                try? Data(
                    contentsOf: URL(fileURLWithPath: location, isDirectory: true)
                        .appendingPathComponent("packages.txt.worktree")
                ),
                Data("custom package list\n".utf8)
            )
        }

        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
        XCTAssertEqual(
            try String(contentsOf: temporaryRoot.appendingPathComponent("Packages/packages.txt")),
            "replacement package list\n"
        )
        XCTAssertEqual(
            try String(contentsOf: movedRoot.appendingPathComponent("Packages/packages.txt")),
            "committed package list\n"
        )
    }

    func testSynchronizeAllPreservesReinstallStateWhenManifestRestorationFails() throws {
        let packageList = try writePackageList("")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "",
            statusError: .commandFailed(command: "Inspect package list", output: "status failed")
        )

        let summary = try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeAll()

        XCTAssertTrue(summary.macEntireRequiresReinstallation)
        XCTAssertTrue(
            summary.statusMessage.hasPrefix(
            "MacEntire updated — reinstall required; "
                + "Could not restore Packages/packages.txt after updating MacEntire: "
                + "Inspect package list failed: status failed"
            )
        )
        XCTAssertTrue(summary.statusMessage.contains("/.git/macentire-recovery/"))
    }

    func testSynchronizeAllPreservesReinstallStateWhenUpdatedRevisionReadFails() throws {
        let packageList = try writePackageList("")
        let readError = PackageSyncError.commandFailed(
            command: "Read updated MacEntire revision",
            output: "process failed"
        )
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "",
            updatedRevisionError: readError
        )

        let summary = try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeAll()

        XCTAssertTrue(summary.macEntireRequiresReinstallation)
        XCTAssertEqual(summary.macEntireErrorMessage, readError.localizedDescription)
        XCTAssertEqual(
            summary.statusMessage,
            "MacEntire updated — reinstall required; \(readError.localizedDescription)"
        )
    }

    func testSynchronizeAllSkipsPackagesWhenManifestRestorationFails() throws {
        let packageList = try writePackageList("https://github.com/sternard/Original-App\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "https://github.com/sternard/Replacement-App\n",
            statusError: .commandFailed(command: "Inspect package list", output: "status failed")
        )

        let summary = try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeAll()

        XCTAssertTrue(summary.macEntireErrorMessage?.contains("Could not restore") == true)
        XCTAssertNil(summary.packageListErrorMessage)
        XCTAssertTrue(summary.packageResults.isEmpty)
        XCTAssertFalse(git.commands.contains { $0.first == "clone" })
    }

    func testSynchronizeAllSkipsPackagesWhileManifestRecoveryIsPending() throws {
        let packageList = try writePackageList("https://github.com/sternard/Original-App\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            revisionAfterFetch: "user-commit",
            packageListEditDuringFetch: "https://github.com/sternard/Replacement-App\n"
        )

        let summary = try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeAll()

        XCTAssertTrue(summary.macEntireErrorMessage?.contains("Original package-list changes were saved") == true)
        XCTAssertNil(summary.packageListErrorMessage)
        XCTAssertTrue(summary.packageResults.isEmpty)
        XCTAssertFalse(git.commands.contains { $0.first == "clone" })
    }

    func testMacEntireUpdatePreservesIndexEditMadeDuringUpdate() throws {
        let packageList = try writePackageList("custom package list\n")
        let stagedObjectID = String(repeating: "1", count: 40)
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            indexEntryOutput: "100644 \(stagedObjectID) 0\tPackages/packages.txt",
            headEntryOutput: "100644 blob \(String(repeating: "0", count: 40))\tPackages/packages.txt",
            packageListEditDuringUpdate: "newer staged edit\n",
            statusOutput: "MM Packages/packages.txt"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronizeMacEntire()

        XCTAssertFalse(git.commands.contains { arguments in
            arguments.contains("update-index") && arguments.contains {
                $0.contains(stagedObjectID)
            }
        })
        XCTAssertEqual(try String(contentsOf: packageList), "newer staged edit\n")
    }

    func testMacEntireUpdateRestoresStagedManifestAfterUnrelatedIndexEdit() throws {
        let packageList = try writePackageList("custom package list\n")
        let stagedObjectID = String(repeating: "1", count: 40)
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            indexEntryOutput: "100644 \(stagedObjectID) 0\tPackages/packages.txt",
            headEntryOutput: "100644 blob \(String(repeating: "0", count: 40))\tPackages/packages.txt",
            packageListEditDuringUpdate: "newer unstaged edit\n",
            indexTouchedDuringUpdate: true,
            statusOutput: " M Packages/packages.txt"
        )

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeMacEntire()

        XCTAssertTrue(git.commands.contains { arguments in
            arguments.contains("update-index") && arguments.contains {
                $0.contains(stagedObjectID)
            }
        })
        XCTAssertEqual(try String(contentsOf: packageList), "newer unstaged edit\n")
    }

    func testMacEntireUpdatePreservesIndexEditStagedBeforeFinalRestoration() throws {
        let packageList = try writePackageList("custom package list\n")
        let originalStagedObjectID = String(repeating: "1", count: 40)
        let concurrentlyStagedObjectID = String(repeating: "2", count: 40)
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            indexEntryOutput: "100644 \(originalStagedObjectID) 0\tPackages/packages.txt",
            headEntryOutput: "100644 blob \(String(repeating: "0", count: 40))\tPackages/packages.txt",
            finalIndexEntryOutput: "100644 \(concurrentlyStagedObjectID) 0\tPackages/packages.txt"
        )

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeMacEntire()

        XCTAssertFalse(git.commands.contains { arguments in
            arguments.contains("update-index") && arguments.contains {
                $0.contains(originalStagedObjectID)
            }
        })
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
    }

    func testMacEntireUpdateDoesNotRequireReinstallationWhenRevisionIsUnchanged() throws {
        let packageList = try writePackageList("custom package list\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            originalRevision: "unchanged",
            updatedRevision: "unchanged"
        )

        let requiresReinstallation = try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeMacEntire()

        XCTAssertFalse(requiresReinstallation)
    }

    func testSynchronizationStatusRequiresReinstallAfterMacEntireUpdate() {
        let summary = SynchronizationSummary(
            macEntireRequiresReinstallation: true,
            packageResults: []
        )

        XCTAssertEqual(
            summary.statusMessage,
            "MacEntire updated — quit and run scripts/install-app.sh to install it"
        )
    }

    func testSynchronizationStatusLimitsGitDiagnosticForMenuDisplay() {
        let messagePrefix = "MacEntire: Fetch MacEntire failed: "
        let error = PackageSyncError.commandFailed(
            command: "Fetch MacEntire",
            output: "first line\nsecond\t\(String(repeating: "x", count: 300))"
        )
        let summary = SynchronizationSummary(
            macEntireErrorMessage: error.localizedDescription,
            packageResults: []
        )

        XCTAssertTrue(summary.statusMessage.hasPrefix(messagePrefix))
        let diagnostic = summary.statusMessage.dropFirst(messagePrefix.count)
        XCTAssertEqual(diagnostic.count, PackageSyncError.maximumDisplayedOutputCharacters)
        XCTAssertFalse(diagnostic.contains(where: \.isNewline))
        XCTAssertFalse(diagnostic.contains("\t"))
        XCTAssertTrue(diagnostic.hasSuffix("…"))
    }

    func testSynchronizeAllPreservesReinstallNoticeWhenPackageListIsInvalid() throws {
        let packageList = try writePackageList("not a repository\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        let summary = try synchronizer.synchronizeAll()

        XCTAssertTrue(summary.macEntireRequiresReinstallation)
        XCTAssertEqual(
            summary.packageListErrorMessage,
            "Invalid package entry on line 1: not a repository"
        )
        XCTAssertEqual(
            summary.statusMessage,
            "MacEntire updated — quit and run scripts/install-app.sh to install it; "
                + "Package list: Invalid package entry on line 1: not a repository"
        )
        XCTAssertTrue(summary.packageResults.isEmpty)
    }

    func testMacEntireUpdateFastForwardsRealRepositoryAndPreservesPartiallyStagedPackageList() throws {
        let remote = temporaryRoot.appendingPathComponent("Remote.git", isDirectory: true)
        let source = temporaryRoot.appendingPathComponent("Source", isDirectory: true)
        let checkout = temporaryRoot.appendingPathComponent("Checkout", isDirectory: true)
        let git = ProcessGitRunner(timeout: 30)

        _ = try git.run(["init", "--bare", remote.path], description: "Create test remote")
        _ = try git.run(["init", source.path], description: "Create test source")
        _ = try git.run(
            ["-C", source.path, "config", "user.name", "MacEntire Tests"],
            description: "Configure test Git name"
        )
        _ = try git.run(
            ["-C", source.path, "config", "user.email", "tests@macentire.local"],
            description: "Configure test Git email"
        )

        let sourcePackages = source.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePackages, withIntermediateDirectories: true)
        try "committed package list\n".write(
            to: sourcePackages.appendingPathComponent("packages.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "version one\n".write(
            to: source.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = try git.run(["-C", source.path, "add", "."], description: "Stage initial test files")
        _ = try git.run(["-C", source.path, "commit", "-m", "Initial"], description: "Commit initial test files")
        let branch = try git.run(
            ["-C", source.path, "branch", "--show-current"],
            description: "Read test branch"
        )
        _ = try git.run(
            ["-C", source.path, "remote", "add", "origin", remote.path],
            description: "Add test remote"
        )
        _ = try git.run(
            ["-C", source.path, "push", "--set-upstream", "origin", branch],
            description: "Push initial test files"
        )
        _ = try git.run(
            ["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/\(branch)"],
            description: "Set test remote HEAD"
        )
        _ = try git.run(["clone", remote.path, checkout.path], description: "Clone test checkout")

        let checkoutPackageList = checkout.appendingPathComponent("Packages/packages.txt")
        try "staged package list\n".write(
            to: checkoutPackageList,
            atomically: true,
            encoding: .utf8
        )
        _ = try git.run(
            ["-C", checkout.path, "add", "Packages/packages.txt"],
            description: "Stage customized test package list"
        )
        try "custom package list\n".write(
            to: checkoutPackageList,
            atomically: true,
            encoding: .utf8
        )
        try "version two\n".write(
            to: source.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "upstream package list\n".write(
            to: sourcePackages.appendingPathComponent("packages.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try git.run(["-C", source.path, "add", "."], description: "Stage upstream test update")
        _ = try git.run(
            ["-C", source.path, "commit", "-m", "Update"],
            description: "Commit upstream test update"
        )
        _ = try git.run(["-C", source.path, "push"], description: "Push upstream test update")

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: checkout),
            gitRunner: git
        ).synchronizeMacEntire()

        XCTAssertEqual(
            try String(contentsOf: checkoutPackageList, encoding: .utf8),
            "custom package list\n"
        )
        XCTAssertEqual(
            try String(contentsOf: checkout.appendingPathComponent("README.md"), encoding: .utf8),
            "version two\n"
        )
        XCTAssertEqual(
            try git.run(
                ["-C", checkout.path, "show", ":Packages/packages.txt"],
                description: "Read preserved staged test customization"
            ),
            "staged package list"
        )
        XCTAssertEqual(
            try git.run(
                ["-C", checkout.path, "status", "--porcelain", "--", "Packages/packages.txt"],
                description: "Check preserved partial test customization"
            ),
            "MM Packages/packages.txt"
        )
    }

    func testMacEntireUpdateRestoresCustomizedIndexEntry() throws {
        let packageList = try writePackageList("custom package list\n")
        let stagedObjectID = String(repeating: "1", count: 40)
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            indexEntryOutput: "100644 \(stagedObjectID) 0\tPackages/packages.txt",
            headEntryOutput: "100644 blob \(String(repeating: "0", count: 40))\tPackages/packages.txt"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronizeMacEntire()

        XCTAssertTrue(git.commands.contains { arguments in
            arguments.suffix(4) == [
                "update-index", "--add", "--cacheinfo",
                "100644,\(stagedObjectID),Packages/packages.txt"
            ]
        })
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
    }

    func testMacEntireUpdateRestoresManifestWorktreePermissions() throws {
        let packageList = try writePackageList("custom package list\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: packageList.path
        )
        let stagedObjectID = String(repeating: "1", count: 40)
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            indexEntryOutput: "100755 \(stagedObjectID) 0\tPackages/packages.txt",
            headEntryOutput: "100644 blob \(String(repeating: "0", count: 40))\tPackages/packages.txt",
            packageListModeDuringRestore: 0o644
        )

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeMacEntire()

        let attributes = try FileManager.default.attributesOfItem(atPath: packageList.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o755)
    }

    func testMacEntireUpdateRestoresCustomizedPackageListWhenPullFails() throws {
        let packageList = try writePackageList("custom package list\n")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "partially updated package list\n",
            updateError: .commandFailed(command: "Update MacEntire", output: "network unavailable")
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronizeMacEntire()) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .commandFailed(command: "Update MacEntire", output: "network unavailable")
            )
        }
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
    }

    func testMacEntireUpdatePreservesSymlinkedPackageListWhenUpdateFails() throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packagesDirectory,
            withIntermediateDirectories: true
        )
        let externalPackageList = temporaryRoot.appendingPathComponent("custom-packages.txt")
        try "custom package list\n".write(
            to: externalPackageList,
            atomically: true,
            encoding: .utf8
        )
        let packageList = packagesDirectory.appendingPathComponent("packages.txt")
        let linkDestination = "../custom-packages.txt"
        try FileManager.default.createSymbolicLink(
            atPath: packageList.path,
            withDestinationPath: linkDestination
        )
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "partially updated package list\n",
            updateError: .commandFailed(command: "Update MacEntire", output: "network unavailable")
        )

        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronizeMacEntire()) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .commandFailed(command: "Update MacEntire", output: "network unavailable")
            )
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: packageList.path),
            linkDestination
        )
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
        XCTAssertEqual(try String(contentsOf: externalPackageList), "custom package list\n")
    }

    func testMacEntireUpdatePreservesSymlinkRetargetedDuringUpdate() throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packagesDirectory,
            withIntermediateDirectories: true
        )
        let originalPackageList = temporaryRoot.appendingPathComponent("custom-packages.txt")
        try "custom package list\n".write(
            to: originalPackageList,
            atomically: true,
            encoding: .utf8
        )
        let newerPackageList = temporaryRoot.appendingPathComponent("newer-packages.txt")
        try "newer package list\n".write(
            to: newerPackageList,
            atomically: true,
            encoding: .utf8
        )
        let packageList = packagesDirectory.appendingPathComponent("packages.txt")
        try FileManager.default.createSymbolicLink(
            atPath: packageList.path,
            withDestinationPath: "../custom-packages.txt"
        )
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "upstream package list\n",
            packageListLinkDestinationDuringUpdate: "../newer-packages.txt",
            statusOutput: " T Packages/packages.txt"
        )

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronizeMacEntire()

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: packageList.path),
            "../newer-packages.txt"
        )
        XCTAssertEqual(try String(contentsOf: packageList), "newer package list\n")
    }

    func testMacEntireUpdateRefusesToPullFromParentRepository() throws {
        _ = try writePackageList("custom package list\n")
        let parentRoot = temporaryRoot.deletingLastPathComponent()
        let git = MacEntireUpdateGitRunner(
            rootDirectory: parentRoot,
            packageListURL: temporaryRoot.appendingPathComponent("Packages/packages.txt"),
            updatedPackageList: "upstream package list\n"
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronizeMacEntire()) { error in
            XCTAssertEqual(error as? PackageSyncError, .macEntireIsNotRepository)
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testSynchronizeAllReportsMacEntireFailureWithoutThrowing() throws {
        let packageList = try writePackageList("")
        let git = MacEntireUpdateGitRunner(
            rootDirectory: temporaryRoot,
            packageListURL: packageList,
            updatedPackageList: "",
            updateError: .commandFailed(command: "Update MacEntire", output: "network unavailable")
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        let summary = try synchronizer.synchronizeAll()

        XCTAssertEqual(
            summary.macEntireErrorMessage,
            "Update MacEntire failed: network unavailable"
        )
        XCTAssertTrue(summary.packageResults.isEmpty)
    }

    func testRefusesToUpdateRepositoryWithLocalChanges() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(statusOutput: " M README.md")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .localChanges("Example-App"))
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testCleanRepositoryFetchesCurrentBranchFromOriginAndFastForwardsSafely() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains {
            $0.suffix(3) == ["fetch", "origin", "refs/heads/main"]
        })
        XCTAssertTrue(git.commands.contains {
            $0.suffix(4) == ["merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"]
        })
        XCTAssertFalse(git.commands.contains { $0.contains("pull") })
    }

    func testCredentialBearingOriginForConfiguredRepositorySynchronizes() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            remoteOutput: "https://x-access-token:secret@github.com/sternard/Example-App.git",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertTrue(git.commands.contains { $0.contains("merge") })
    }

    func testConfiguredBranchFetchesExplicitlyFromOriginAndFastForwardsSafely() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = FakeGitRunner(currentBranchOutput: "develop", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains {
            $0.suffix(3) == ["fetch", "origin", "refs/heads/develop"]
        })
        XCTAssertTrue(git.commands.contains {
            $0.suffix(4) == ["merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"]
        })
        XCTAssertFalse(git.commands.contains { $0.contains("pull") })
    }

    func testRefusesConfiguredBranchMismatch() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = FakeGitRunner(currentBranchOutput: "main", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .branchMismatch(repository: "Example-App", expected: "develop", actual: "main")
            )
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testRefusesConfiguredBranchChangedDuringFetch() throws {
        let package = try makeInstalledPackage(branch: "develop")
        let git = FakeGitRunner(
            currentBranchOutput: "develop",
            currentBranchOutputAfterFetch: "main",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .branchMismatch(repository: "Example-App", expected: "develop", actual: "main")
            )
        }
        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testRefusesPackageRevisionChangedDuringFetch() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            revisionOutput: "original-revision",
            revisionOutputAfterFetch: "user-reset-revision",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .branchRevisionChanged("Example-App")
            )
        }
        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testRefusesLocalChangesMadeDuringFetch() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            statusOutput: "",
            statusOutputAfterFetch: " M Notes.txt"
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronize(package)
        ) { error in
            XCTAssertEqual(error as? PackageSyncError, .localChanges("Example-App"))
        }
        XCTAssertEqual(
            git.commands.filter { $0.suffix(2) == ["status", "--porcelain"] }.count,
            2
        )
        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testRefusesMergeAfterManagedCheckoutIsReplacedDuringFetch() throws {
        let package = try makeInstalledPackage()
        let movedCheckout = temporaryRoot.appendingPathComponent(
            "Moved-Example-App",
            isDirectory: true
        )
        let git = FakeGitRunner(statusOutput: "")
        git.fetchHandler = {
            try FileManager.default.moveItem(
                at: package.directoryURL,
                to: movedCheckout
            )
            try FileManager.default.createDirectory(
                at: package.directoryURL.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronize(package)
        ) { error in
            XCTAssertEqual(error as? PackageSyncError, .checkoutChanged("Example-App"))
        }
        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testRefusesMergeAfterManagedPackagesDirectoryIsReplacedDuringFetch() throws {
        let package = try makeInstalledPackage()
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let movedPackagesDirectory = temporaryRoot.appendingPathComponent(
            "Moved-Packages",
            isDirectory: true
        )
        let git = FakeGitRunner(statusOutput: "")
        git.fetchHandler = {
            try FileManager.default.moveItem(
                at: packagesDirectory,
                to: movedPackagesDirectory
            )
            try FileManager.default.createDirectory(
                at: package.directoryURL.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronize(package)
        ) { error in
            XCTAssertEqual(error as? PackageSyncError, .checkoutChanged("Example-App"))
        }
        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testRefusesOriginChangedDuringFetch() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            rawRemoteOutputAfterFetch: "https://github.com/someone-else/Example-App",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .remoteMismatch(
                    expected: "https://github.com/sternard/Example-App",
                    actual: "https://github.com/someone-else/Example-App"
                )
            )
        }
        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
        XCTAssertFalse(git.commands.contains { $0.contains("merge") })
    }

    func testRefusesDetachedHead() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(currentBranchOutput: "", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .detachedHead("Example-App"))
        }
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testMissingRepositoryClonesConfiguredBranch() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: "release/next",
            directoryURL: directory
        )
        let git = FakeGitRunner(currentBranchOutput: "release/next", statusOutput: "") { arguments in
            let cloneDirectory = URL(fileURLWithPath: try XCTUnwrap(arguments.last), isDirectory: true)
            try FileManager.default.createDirectory(
                at: cloneDirectory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try self.writeExecutableLauncher(
                at: cloneDirectory.appendingPathComponent("scripts/run-app.sh")
            )
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertEqual(git.commands.count, 4)
        XCTAssertEqual(git.commands[0], [
            "ls-remote", "--get-url", "https://github.com/sternard/Example-App"
        ])
        XCTAssertEqual(git.commands[1].dropLast(), [
            "clone", "--origin", "origin", "--branch", "release/next", "--single-branch",
            "https://github.com/sternard/Example-App"
        ])
        XCTAssertTrue(try XCTUnwrap(git.commands[1].last).hasPrefix("/.vol/"))
        XCTAssertEqual(git.commands[2].suffix(3), ["config", "--get-all", "remote.origin.url"])
        XCTAssertEqual(git.commands[3].suffix(2), ["branch", "--show-current"])
    }

    func testFailedCloneRemovesReservedCheckoutSoSynchronizationCanRetry() throws {
        let directory = temporaryRoot.appendingPathComponent(
            "Packages/Example-App",
            isDirectory: true
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: directory
        )
        let failedGit = FakeGitRunner(statusOutput: "") { arguments in
            let cloneDirectory = URL(
                fileURLWithPath: try XCTUnwrap(arguments.last),
                isDirectory: true
            )
            try Data("partial clone".utf8).write(
                to: cloneDirectory.appendingPathComponent("partial-pack"),
                options: .atomic
            )
            throw PackageSyncError.commandFailed(
                command: "Clone Example-App",
                output: "network unavailable"
            )
        }

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: failedGit
            ).synchronize(package)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let retryGit = FakeGitRunner(statusOutput: "") { arguments in
            let cloneDirectory = URL(
                fileURLWithPath: try XCTUnwrap(arguments.last),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: cloneDirectory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try self.writeExecutableLauncher(
                at: cloneDirectory.appendingPathComponent("scripts/run-app.sh")
            )
        }

        XCTAssertNoThrow(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: retryGit
            ).synchronize(package)
        )
        XCTAssertEqual(retryGit.commands.first, [
            "ls-remote", "--get-url", "https://github.com/sternard/Example-App"
        ])
        XCTAssertEqual(retryGit.commands.dropFirst().first?.first, "clone")
    }

    func testFailedCloneDoesNotDeleteReservedCheckoutAfterItIsMoved() throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let directory = packagesDirectory.appendingPathComponent("Example-App", isDirectory: true)
        let movedDirectory = temporaryRoot.appendingPathComponent(
            "Moved-Example-App",
            isDirectory: true
        )
        let externalDirectory = temporaryRoot.appendingPathComponent(
            "External-Example-App",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: directory
        )
        let git = FakeGitRunner(statusOutput: "") { arguments in
            let cloneDirectory = URL(
                fileURLWithPath: try XCTUnwrap(arguments.last),
                isDirectory: true
            )
            try Data("partial clone".utf8).write(
                to: cloneDirectory.appendingPathComponent("partial-pack"),
                options: .atomic
            )
            try FileManager.default.moveItem(at: directory, to: movedDirectory)
            try Data("unrelated".utf8).write(
                to: movedDirectory.appendingPathComponent("unrelated-file"),
                options: .atomic
            )
            try FileManager.default.createSymbolicLink(
                at: directory,
                withDestinationURL: externalDirectory
            )
            throw PackageSyncError.commandFailed(
                command: "Clone Example-App",
                output: "network unavailable"
            )
        }

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronize(package)
        )
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: movedDirectory.path)),
            ["partial-pack", "unrelated-file"]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: externalDirectory.path),
            []
        )
    }

    func testCloneWithRewrittenTransportUsesStoredOrigin() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: directory
        )
        let git = FakeGitRunner(
            effectiveCloneURL: "git@github.com:sternard/Example-App.git",
            remoteOutput: "git@github.com:sternard/Example-App.git",
            rawRemoteOutput: "https://github.com/sternard/Example-App",
            statusOutput: ""
        ) { arguments in
            let cloneDirectory = URL(fileURLWithPath: try XCTUnwrap(arguments.last), isDirectory: true)
            try FileManager.default.createDirectory(
                at: cloneDirectory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try self.writeExecutableLauncher(
                at: cloneDirectory.appendingPathComponent("scripts/run-app.sh")
            )
        }

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronize(package)

        XCTAssertTrue(git.commands.contains {
            $0.suffix(3) == ["config", "--get-all", "remote.origin.url"]
        })
        XCTAssertTrue(git.commands.contains {
            $0.first == "clone"
                && $0.dropLast().last == "https://github.com/sternard/Example-App"
        })
    }

    func testRefusesCloneWhenURLRewriteChangesRepositoryIdentity() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: directory
        )
        let git = FakeGitRunner(
            effectiveCloneURL: "git@github.com:someone-else/Example-App.git",
            statusOutput: ""
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronize(package)
        ) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .remoteMismatch(
                    expected: "https://github.com/sternard/Example-App",
                    actual: "git@github.com:someone-else/Example-App.git"
                )
            )
        }
        XCTAssertEqual(git.commands, [[
            "ls-remote", "--get-url", "https://github.com/sternard/Example-App"
        ]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRefusesCloneWhoseEffectiveOriginDoesNotMatchConfiguration() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: directory
        )
        let git = FakeGitRunner(
            remoteOutput: "https://github.com/someone-else/Example-App",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .remoteMismatch(
                    expected: "https://github.com/sternard/Example-App",
                    actual: "https://github.com/someone-else/Example-App"
                )
            )
        }
        XCTAssertEqual(git.commands.count, 3)
        XCTAssertEqual(git.commands[0], [
            "ls-remote", "--get-url", "https://github.com/sternard/Example-App"
        ])
        XCTAssertEqual(git.commands[1].dropLast(), [
            "clone", "--origin", "origin", "https://github.com/sternard/Example-App"
        ])
        XCTAssertTrue(try XCTUnwrap(git.commands[1].last).hasPrefix("/.vol/"))
        XCTAssertEqual(git.commands[2].suffix(3), ["config", "--get-all", "remote.origin.url"])
    }

    func testRefusesConfiguredBranchCloneThatLandsOnDetachedHead() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: "release",
            directoryURL: directory
        )
        let git = FakeGitRunner(currentBranchOutput: "", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .detachedHead("Example-App"))
        }
        XCTAssertEqual(git.commands.count, 4)
        XCTAssertEqual(git.commands[0], [
            "ls-remote", "--get-url", "https://github.com/sternard/Example-App"
        ])
        XCTAssertEqual(git.commands[1].dropLast(), [
            "clone", "--origin", "origin", "--branch", "release", "--single-branch",
            "https://github.com/sternard/Example-App"
        ])
        XCTAssertTrue(try XCTUnwrap(git.commands[1].last).hasPrefix("/.vol/"))
        XCTAssertEqual(git.commands[2].suffix(3), ["config", "--get-all", "remote.origin.url"])
        XCTAssertEqual(git.commands[3].suffix(2), ["branch", "--show-current"])
    }

    func testRefusesDefaultBranchCloneThatLandsOnDetachedHead() throws {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: directory
        )
        let git = FakeGitRunner(currentBranchOutput: "", statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .detachedHead("Example-App"))
        }
        XCTAssertEqual(git.commands.count, 4)
        XCTAssertEqual(git.commands[0], [
            "ls-remote", "--get-url", "https://github.com/sternard/Example-App"
        ])
        XCTAssertEqual(git.commands[1].dropLast(), [
            "clone", "--origin", "origin", "https://github.com/sternard/Example-App"
        ])
        XCTAssertTrue(try XCTUnwrap(git.commands[1].last).hasPrefix("/.vol/"))
        XCTAssertEqual(git.commands[2].suffix(3), ["config", "--get-all", "remote.origin.url"])
        XCTAssertEqual(git.commands[3].suffix(2), ["branch", "--show-current"])
    }

    func testRefusesRepositoryWithUnexpectedOrigin() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            remoteOutput: "https://x-access-token:secret@github.com/someone-else/Example-App",
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .remoteMismatch(
                    expected: "https://github.com/sternard/Example-App",
                    actual: "https://github.com/someone-else/Example-App"
                )
            )
        }
        XCTAssertFalse(git.commands.contains {
            $0.contains("status") || $0.contains("fetch") || $0.contains("merge")
        })
    }

    func testRefusesAmbiguousStoredFetchURLs() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            rawRemoteOutput: [
                "https://github.com/someone-else/Example-App",
                "https://github.com/sternard/Example-App"
            ].joined(separator: "\n"),
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .remoteMismatch(
                    expected: "https://github.com/sternard/Example-App",
                    actual: "https://github.com/someone-else/Example-App, "
                        + "https://github.com/sternard/Example-App"
                )
            )
        }
        XCTAssertFalse(git.commands.contains {
            $0.contains("status") || $0.contains("fetch") || $0.contains("merge")
        })
    }

    func testRefusesCheckoutThatGitResolvesToParentRepository() throws {
        let package = try makeInstalledPackage()
        let git = FakeGitRunner(
            topLevelOutput: temporaryRoot.path,
            statusOutput: ""
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .destinationIsNotRepository("Example-App"))
        }
        XCTAssertEqual(git.commands.count, 1)
        XCTAssertEqual(git.commands[0].suffix(2), ["rev-parse", "--show-toplevel"])
    }

    func testRefusesCheckoutWhoseGitMetadataEscapesTheCheckout() throws {
        let package = try makeInstalledPackage()
        let gitDirectory = package.directoryURL.appendingPathComponent(".git", isDirectory: true)
        let externalGitDirectory = temporaryRoot.appendingPathComponent(
            "External-Example-App.git",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: gitDirectory, to: externalGitDirectory)
        try FileManager.default.createSymbolicLink(
            at: gitDirectory,
            withDestinationURL: externalGitDirectory
        )
        let git = FakeGitRunner(
            gitDirectoryOutput: externalGitDirectory.path,
            statusOutput: ""
        )

        XCTAssertThrowsError(
            try PackageSynchronizer(
                workspace: PackageWorkspace(rootDirectory: temporaryRoot),
                gitRunner: git
            ).synchronize(package)
        ) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .gitMetadataOutsideCheckout("Example-App")
            )
        }
        XCTAssertTrue(git.commands.contains {
            $0.suffix(2) == ["rev-parse", "--absolute-git-dir"]
        })
        XCTAssertFalse(git.commands.contains { $0.contains("fetch") || $0.contains("merge") })
    }

    func testUpdatesCheckoutUnderSymlinkedWorkspaceAncestor() throws {
        let physicalRoot = temporaryRoot.appendingPathComponent("PhysicalRoot", isDirectory: true)
        let linkedRoot = temporaryRoot.appendingPathComponent("LinkedRoot", isDirectory: true)
        let physicalDirectory = physicalRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalDirectory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: physicalDirectory.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeExecutableLauncher(
            at: physicalDirectory.appendingPathComponent("scripts/run-app.sh")
        )
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: physicalRoot)
        let linkedDirectory = linkedRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: linkedDirectory
        )
        let git = FakeGitRunner(topLevelOutput: physicalDirectory.path, statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: linkedRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertTrue(git.commands.contains { $0.contains("fetch") })
    }

    func testRefusesSymlinkedCheckoutDirectory() throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let externalDirectory = temporaryRoot.appendingPathComponent("External-Example-App", isDirectory: true)
        let checkoutDirectory = packagesDirectory.appendingPathComponent("Example-App", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: checkoutDirectory, withDestinationURL: externalDirectory)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: checkoutDirectory
        )
        let git = FakeGitRunner(statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .symbolicLinkCheckout("Example-App"))
        }
        XCTAssertTrue(git.commands.isEmpty)
    }

    func testRefusesSymlinkedPackagesDirectory() throws {
        let externalPackagesDirectory = temporaryRoot.appendingPathComponent(
            "External-Packages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalPackagesDirectory,
            withIntermediateDirectories: true
        )
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: packagesDirectory,
            withDestinationURL: externalPackagesDirectory
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: packagesDirectory.appendingPathComponent("Example-App", isDirectory: true)
        )
        let git = FakeGitRunner(statusOutput: "")
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .symbolicLinkPackagesDirectory)
        }
        XCTAssertTrue(git.commands.isEmpty)
    }

    func testCloneStaysInOpenedPackagesDirectoryAfterPathIsReplaced() throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let originalPackagesDirectory = temporaryRoot.appendingPathComponent(
            "Original-Packages",
            isDirectory: true
        )
        let externalPackagesDirectory = temporaryRoot.appendingPathComponent(
            "External-Packages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: externalPackagesDirectory,
            withIntermediateDirectories: true
        )
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: packagesDirectory.appendingPathComponent("Example-App", isDirectory: true)
        )
        let git = FakeGitRunner(statusOutput: "") { arguments in
            try FileManager.default.moveItem(
                at: packagesDirectory,
                to: originalPackagesDirectory
            )
            try FileManager.default.createSymbolicLink(
                at: packagesDirectory,
                withDestinationURL: externalPackagesDirectory
            )

            let cloneDirectory = URL(
                fileURLWithPath: try XCTUnwrap(arguments.last),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: cloneDirectory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try self.writeExecutableLauncher(
                at: cloneDirectory.appendingPathComponent("scripts/run-app.sh")
            )
        }

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronize(package)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: originalPackagesDirectory
                .appendingPathComponent("Example-App/scripts/run-app.sh")
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: externalPackagesDirectory.appendingPathComponent("Example-App").path
        ))
    }

    func testCloneStaysInReservedCheckoutWhenVisibleDestinationIsReplaced() throws {
        let packagesDirectory = temporaryRoot.appendingPathComponent("Packages", isDirectory: true)
        let reservedCheckout = temporaryRoot.appendingPathComponent(
            "Reserved-Example-App",
            isDirectory: true
        )
        let externalCheckout = temporaryRoot.appendingPathComponent(
            "External-Example-App",
            isDirectory: true
        )
        let visibleCheckout = packagesDirectory.appendingPathComponent(
            "Example-App",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalCheckout, withIntermediateDirectories: true)
        let package = PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            directoryURL: visibleCheckout
        )
        let git = FakeGitRunner(statusOutput: "") { arguments in
            XCTAssertTrue(FileManager.default.fileExists(atPath: visibleCheckout.path))
            try FileManager.default.moveItem(at: visibleCheckout, to: reservedCheckout)
            try FileManager.default.createSymbolicLink(
                at: visibleCheckout,
                withDestinationURL: externalCheckout
            )

            let cloneDirectory = URL(
                fileURLWithPath: try XCTUnwrap(arguments.last),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: cloneDirectory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try self.writeExecutableLauncher(
                at: cloneDirectory.appendingPathComponent("scripts/run-app.sh")
            )
        }

        try PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        ).synchronize(package)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: reservedCheckout.appendingPathComponent("scripts/run-app.sh").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: externalCheckout.path),
            []
        )
    }

    func testRefusesLauncherDirectory() throws {
        let package = try makeInstalledPackage()
        try FileManager.default.removeItem(at: package.launcherURL)
        try FileManager.default.createDirectory(at: package.launcherURL, withIntermediateDirectories: false)
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: FakeGitRunner(statusOutput: "")
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .missingLauncher("Example-App"))
        }
    }

    func testRefusesLauncherSymlinkToDirectory() throws {
        let package = try makeInstalledPackage()
        try FileManager.default.removeItem(at: package.launcherURL)
        let launcherDirectory = package.directoryURL.appendingPathComponent("LauncherDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: package.launcherURL, withDestinationURL: launcherDirectory)
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: FakeGitRunner(statusOutput: "")
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(error as? PackageSyncError, .missingLauncher("Example-App"))
        }
    }

    func testRefusesNonExecutableLauncher() throws {
        let package = try makeInstalledPackage()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: package.launcherURL.path
        )
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: FakeGitRunner(statusOutput: "")
        )

        XCTAssertThrowsError(try synchronizer.synchronize(package)) { error in
            XCTAssertEqual(
                error as? PackageSyncError,
                .nonExecutableLauncher("Example-App")
            )
        }
    }

    private func makeInstalledPackage(branch: String? = nil) throws -> PackageDefinition {
        let directory = temporaryRoot.appendingPathComponent("Packages/Example-App", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeExecutableLauncher(
            at: directory.appendingPathComponent("scripts/run-app.sh")
        )

        return PackageDefinition(
            repositoryURL: URL(string: "https://github.com/sternard/Example-App")!,
            repositoryName: "Example-App",
            displayName: "Example App",
            branch: branch,
            directoryURL: directory
        )
    }

    private func writeExecutableLauncher(at url: URL) throws {
        try "#!/usr/bin/env bash\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    @discardableResult
    private func writePackageList(_ contents: String) throws -> URL {
        let packageList = temporaryRoot.appendingPathComponent("Packages/packages.txt")
        try FileManager.default.createDirectory(
            at: packageList.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: packageList, atomically: true, encoding: .utf8)
        return packageList
    }
}

private final class MacEntireUpdateGitRunner: GitRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private let rootDirectory: URL
    private let packageListURL: URL
    private let updatedPackageList: String
    private let updateError: PackageSyncError?
    private let fetchError: PackageSyncError?
    private let indexEntryOutput: String
    private let headEntryOutput: String
    private let originalRevision: String
    private let revisionAfterFetch: String?
    private let updatedRevision: String
    private let updatedRevisionError: PackageSyncError?
    private let currentBranchOutput: String
    private let currentBranchOutputAfterFetch: String?
    private let packageListEditDuringFetch: String?
    private let packageListEditDuringUpdate: String?
    private let packageListEditAfterStatusCheck: String?
    private let packageListLinkDestinationDuringUpdate: String?
    private let packageListModeDuringRestore: Int?
    private let packagesDirectoryReplacementDuringStatus: URL?
    private let rootDirectoryMoveDestinationDuringFetch: URL?
    private let indexTouchedDuringUpdate: Bool
    private let finalIndexEntryOutput: String?
    private let statusError: PackageSyncError?
    private let statusOutput: String?
    private var didMerge = false
    private var didFetch = false
    private var didRestorePackageList = false
    private var didCheckStatus = false
    private var restoredIndexReadCount = 0

    init(
        rootDirectory: URL,
        packageListURL: URL,
        updatedPackageList: String,
        updateError: PackageSyncError? = nil,
        fetchError: PackageSyncError? = nil,
        indexEntryOutput: String? = nil,
        headEntryOutput: String? = nil,
        originalRevision: String = "old-revision",
        revisionAfterFetch: String? = nil,
        updatedRevision: String = "new-revision",
        updatedRevisionError: PackageSyncError? = nil,
        currentBranchOutput: String = "main",
        currentBranchOutputAfterFetch: String? = nil,
        packageListEditDuringFetch: String? = nil,
        packageListEditDuringUpdate: String? = nil,
        packageListEditAfterStatusCheck: String? = nil,
        packageListLinkDestinationDuringUpdate: String? = nil,
        packageListModeDuringRestore: Int? = nil,
        packagesDirectoryReplacementDuringStatus: URL? = nil,
        rootDirectoryMoveDestinationDuringFetch: URL? = nil,
        indexTouchedDuringUpdate: Bool = false,
        finalIndexEntryOutput: String? = nil,
        statusError: PackageSyncError? = nil,
        statusOutput: String? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.packageListURL = packageListURL
        self.updatedPackageList = updatedPackageList
        self.updateError = updateError
        self.fetchError = fetchError
        self.originalRevision = originalRevision
        self.revisionAfterFetch = revisionAfterFetch
        self.updatedRevision = updatedRevision
        self.updatedRevisionError = updatedRevisionError
        self.currentBranchOutput = currentBranchOutput
        self.currentBranchOutputAfterFetch = currentBranchOutputAfterFetch
        self.packageListEditDuringFetch = packageListEditDuringFetch
        self.packageListEditDuringUpdate = packageListEditDuringUpdate
        self.packageListEditAfterStatusCheck = packageListEditAfterStatusCheck
        self.packageListLinkDestinationDuringUpdate = packageListLinkDestinationDuringUpdate
        self.packageListModeDuringRestore = packageListModeDuringRestore
        self.packagesDirectoryReplacementDuringStatus = packagesDirectoryReplacementDuringStatus
        self.rootDirectoryMoveDestinationDuringFetch = rootDirectoryMoveDestinationDuringFetch
        self.indexTouchedDuringUpdate = indexTouchedDuringUpdate
        self.finalIndexEntryOutput = finalIndexEntryOutput
        self.statusError = statusError
        self.statusOutput = statusOutput
        let unchangedObjectID = String(repeating: "0", count: 40)
        self.indexEntryOutput = indexEntryOutput
            ?? "100644 \(unchangedObjectID) 0\tPackages/packages.txt"
        self.headEntryOutput = headEntryOutput
            ?? "100644 blob \(unchangedObjectID)\tPackages/packages.txt"
    }

    func run(_ arguments: [String], description: String) throws -> String {
        commands.append(arguments)
        if arguments.suffix(2) == ["rev-parse", "HEAD"] {
            if didMerge {
                if let updatedRevisionError {
                    throw updatedRevisionError
                }
                return updatedRevision
            }
            return didFetch ? revisionAfterFetch ?? originalRevision : originalRevision
        }
        if arguments.suffix(3) == ["rev-parse", "--git-path", "index"] {
            let indexURL = rootDirectory.appendingPathComponent(".git/index")
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: indexURL.path) {
                try Data("test index".utf8).write(to: indexURL, options: .atomic)
            }
            return ".git/index"
        }
        if arguments.contains("rev-parse") {
            return rootDirectory.path
        }
        if arguments.contains("branch") {
            return didFetch ? currentBranchOutputAfterFetch ?? currentBranchOutput : currentBranchOutput
        }
        if arguments.contains("ls-files") {
            if didCheckStatus, let packageListEditAfterStatusCheck {
                try packageListEditAfterStatusCheck.write(
                    to: packageListURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            if didRestorePackageList {
                restoredIndexReadCount += 1
                if restoredIndexReadCount > 1, let finalIndexEntryOutput {
                    return finalIndexEntryOutput
                }
                return restoredPackageListIndexEntryOutput
            }
            return indexEntryOutput
        }
        if arguments.contains("ls-tree") {
            return headEntryOutput
        }
        if arguments.contains("restore") {
            didRestorePackageList = true
            try "committed package list\n".write(
                to: packageListURL,
                atomically: true,
                encoding: .utf8
            )
            if let packageListModeDuringRestore {
                try FileManager.default.setAttributes(
                    [.posixPermissions: packageListModeDuringRestore],
                    ofItemAtPath: packageListURL.path
                )
            }
        }
        if arguments.contains("fetch") {
            didFetch = true
            if indexTouchedDuringUpdate {
                let indexURL = rootDirectory.appendingPathComponent(".git/index")
                try Data("test index".utf8).write(to: indexURL, options: .atomic)
            }
            if let packageListEditDuringFetch {
                try packageListEditDuringFetch.write(
                    to: packageListURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            if let rootDirectoryMoveDestinationDuringFetch {
                try FileManager.default.moveItem(
                    at: rootDirectory,
                    to: rootDirectoryMoveDestinationDuringFetch
                )
                try FileManager.default.createDirectory(
                    at: rootDirectory.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: rootDirectory.appendingPathComponent("Packages", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try "replacement package list\n".write(
                    to: packageListURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            if let fetchError {
                throw fetchError
            }
        }
        if arguments.contains("merge") {
            try updatedPackageList.write(to: packageListURL, atomically: true, encoding: .utf8)
            didMerge = true
            if let packageListEditDuringUpdate {
                try packageListEditDuringUpdate.write(
                    to: packageListURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            if let packageListLinkDestinationDuringUpdate {
                if
                    FileManager.default.fileExists(atPath: packageListURL.path)
                        || isSymbolicLink(at: packageListURL)
                {
                    try FileManager.default.removeItem(at: packageListURL)
                }
                try FileManager.default.createSymbolicLink(
                    atPath: packageListURL.path,
                    withDestinationPath: packageListLinkDestinationDuringUpdate
                )
            }
            if let updateError {
                throw updateError
            }
        }
        if arguments.contains("status") {
            didCheckStatus = true
            if let packagesDirectoryReplacementDuringStatus {
                let packagesDirectory = packageListURL.deletingLastPathComponent()
                try FileManager.default.moveItem(
                    at: packagesDirectory,
                    to: rootDirectory.appendingPathComponent("Original-Packages", isDirectory: true)
                )
                try FileManager.default.createSymbolicLink(
                    at: packagesDirectory,
                    withDestinationURL: packagesDirectoryReplacementDuringStatus
                )
            }
            if let statusError {
                throw statusError
            }
            if let statusOutput {
                return statusOutput
            }
            if packageListEditDuringUpdate != nil {
                return " M Packages/packages.txt"
            }
        }
        return ""
    }

    private var restoredPackageListIndexEntryOutput: String {
        let metadata = headEntryOutput.split(whereSeparator: \.isWhitespace)
        guard metadata.count >= 3 else {
            return ""
        }
        return "\(metadata[0]) \(metadata[2]) 0\tPackages/packages.txt"
    }
}

private final class FakeGitRunner: GitRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private let effectiveCloneURL: String?
    private let remoteOutput: String
    private let rawRemoteOutput: String?
    private let rawRemoteOutputAfterFetch: String?
    private let topLevelOutput: String?
    private let gitDirectoryOutput: String?
    private let revisionOutput: String
    private let revisionOutputAfterFetch: String?
    private let currentBranchOutput: String
    private let currentBranchOutputAfterFetch: String?
    private let statusOutput: String
    private let statusOutputAfterFetch: String?
    var fetchHandler: (() throws -> Void)? = nil
    private let cloneHandler: (([String]) throws -> Void)?
    private var didFetch = false

    init(
        effectiveCloneURL: String? = nil,
        remoteOutput: String = "https://github.com/sternard/Example-App.git",
        rawRemoteOutput: String? = nil,
        rawRemoteOutputAfterFetch: String? = nil,
        topLevelOutput: String? = nil,
        gitDirectoryOutput: String? = nil,
        revisionOutput: String = "current-revision",
        revisionOutputAfterFetch: String? = nil,
        currentBranchOutput: String = "main",
        currentBranchOutputAfterFetch: String? = nil,
        statusOutput: String,
        statusOutputAfterFetch: String? = nil,
        cloneHandler: (([String]) throws -> Void)? = nil
    ) {
        self.effectiveCloneURL = effectiveCloneURL
        self.remoteOutput = remoteOutput
        self.rawRemoteOutput = rawRemoteOutput
        self.rawRemoteOutputAfterFetch = rawRemoteOutputAfterFetch
        self.topLevelOutput = topLevelOutput
        self.gitDirectoryOutput = gitDirectoryOutput
        self.revisionOutput = revisionOutput
        self.revisionOutputAfterFetch = revisionOutputAfterFetch
        self.currentBranchOutput = currentBranchOutput
        self.currentBranchOutputAfterFetch = currentBranchOutputAfterFetch
        self.statusOutput = statusOutput
        self.statusOutputAfterFetch = statusOutputAfterFetch
        self.cloneHandler = cloneHandler
    }

    func run(_ arguments: [String], description: String) throws -> String {
        commands.append(arguments)
        if arguments.prefix(2) == ["ls-remote", "--get-url"] {
            return effectiveCloneURL ?? arguments.last ?? ""
        }
        if arguments.suffix(2) == ["rev-parse", "HEAD"] {
            return didFetch ? revisionOutputAfterFetch ?? revisionOutput : revisionOutput
        }
        if arguments.suffix(2) == ["rev-parse", "--absolute-git-dir"] {
            return gitDirectoryOutput ?? "\(arguments[1])/.git"
        }
        if arguments.contains("rev-parse") {
            return topLevelOutput ?? arguments[1]
        }
        if arguments.suffix(3) == ["config", "--get-all", "remote.origin.url"] {
            if didFetch, let rawRemoteOutputAfterFetch {
                return rawRemoteOutputAfterFetch
            }
            return rawRemoteOutput ?? remoteOutput
        }
        if arguments.contains("remote") {
            return remoteOutput
        }
        if arguments.contains("branch") {
            return didFetch ? currentBranchOutputAfterFetch ?? currentBranchOutput : currentBranchOutput
        }
        if arguments.contains("status") {
            return didFetch ? statusOutputAfterFetch ?? statusOutput : statusOutput
        }
        if arguments.contains("fetch") {
            didFetch = true
            try fetchHandler?()
        }
        if arguments.first == "clone" {
            try cloneHandler?(arguments)
            if let destination = arguments.last {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: destination, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }
        return ""
    }
}
