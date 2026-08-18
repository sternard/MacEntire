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
        XCTAssertEqual(git.commands, [
            ["-C", temporaryRoot.path, "rev-parse", "--show-toplevel"],
            ["-C", temporaryRoot.path, "rev-parse", "HEAD"],
            ["-C", temporaryRoot.path, "ls-files", "--stage", "--", "Packages/packages.txt"],
            ["-C", temporaryRoot.path, "ls-tree", "HEAD", "--", "Packages/packages.txt"],
            [
                "-C", temporaryRoot.path,
                "restore", "--source=HEAD", "--staged", "--worktree", "--", "Packages/packages.txt"
            ],
            ["-C", temporaryRoot.path, "fetch"],
            ["-C", temporaryRoot.path, "merge", "--ff-only", "--no-overwrite-ignore", "@{upstream}"],
            ["-C", temporaryRoot.path, "rev-parse", "HEAD"],
            ["-C", temporaryRoot.path, "status", "--porcelain", "--", "Packages/packages.txt"]
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

        XCTAssertTrue(git.commands.contains([
            "-C", temporaryRoot.path,
            "update-index", "--add", "--cacheinfo",
            "100644,\(stagedObjectID),Packages/packages.txt"
        ]))
        XCTAssertEqual(try String(contentsOf: packageList), "custom package list\n")
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
        let git = FakeGitRunner(currentBranchOutput: "release/next", statusOutput: "") {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("scripts", isDirectory: true),
                withIntermediateDirectories: true
            )
            try self.writeExecutableLauncher(
                at: directory.appendingPathComponent("scripts/run-app.sh")
            )
        }
        let synchronizer = PackageSynchronizer(
            workspace: PackageWorkspace(rootDirectory: temporaryRoot),
            gitRunner: git
        )

        try synchronizer.synchronize(package)

        XCTAssertEqual(git.commands, [
            [
                "clone", "--origin", "origin", "--branch", "release/next", "--single-branch",
                "https://github.com/sternard/Example-App", directory.path
            ],
            ["-C", directory.path, "remote", "get-url", "origin"],
            ["-C", directory.path, "branch", "--show-current"]
        ])
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
        XCTAssertEqual(git.commands, [
            [
                "clone", "--origin", "origin",
                "https://github.com/sternard/Example-App", directory.path
            ],
            ["-C", directory.path, "remote", "get-url", "origin"]
        ])
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
        XCTAssertEqual(git.commands, [
            [
                "clone", "--origin", "origin", "--branch", "release", "--single-branch",
                "https://github.com/sternard/Example-App", directory.path
            ],
            ["-C", directory.path, "remote", "get-url", "origin"],
            ["-C", directory.path, "branch", "--show-current"]
        ])
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
        XCTAssertEqual(git.commands, [
            [
                "clone", "--origin", "origin",
                "https://github.com/sternard/Example-App", directory.path
            ],
            ["-C", directory.path, "remote", "get-url", "origin"],
            ["-C", directory.path, "branch", "--show-current"]
        ])
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
        XCTAssertEqual(git.commands, [
            ["-C", package.directoryURL.path, "rev-parse", "--show-toplevel"]
        ])
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
    private let indexEntryOutput: String
    private let headEntryOutput: String
    private let originalRevision: String
    private let updatedRevision: String
    private let packageListEditDuringUpdate: String?
    private let statusError: PackageSyncError?
    private let statusOutput: String?
    private var didMerge = false

    init(
        rootDirectory: URL,
        packageListURL: URL,
        updatedPackageList: String,
        updateError: PackageSyncError? = nil,
        indexEntryOutput: String? = nil,
        headEntryOutput: String? = nil,
        originalRevision: String = "old-revision",
        updatedRevision: String = "new-revision",
        packageListEditDuringUpdate: String? = nil,
        statusError: PackageSyncError? = nil,
        statusOutput: String? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.packageListURL = packageListURL
        self.updatedPackageList = updatedPackageList
        self.updateError = updateError
        self.originalRevision = originalRevision
        self.updatedRevision = updatedRevision
        self.packageListEditDuringUpdate = packageListEditDuringUpdate
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
            return didMerge ? updatedRevision : originalRevision
        }
        if arguments.contains("rev-parse") {
            return rootDirectory.path
        }
        if arguments.contains("ls-files") {
            return indexEntryOutput
        }
        if arguments.contains("ls-tree") {
            return headEntryOutput
        }
        if arguments.contains("restore") {
            try "committed package list\n".write(
                to: packageListURL,
                atomically: true,
                encoding: .utf8
            )
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
            if let updateError {
                throw updateError
            }
        }
        if arguments.contains("status") {
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
}

private final class FakeGitRunner: GitRunning, @unchecked Sendable {
    private(set) var commands: [[String]] = []
    private let remoteOutput: String
    private let topLevelOutput: String?
    private let currentBranchOutput: String
    private let statusOutput: String
    private let cloneHandler: (() throws -> Void)?

    init(
        remoteOutput: String = "https://github.com/sternard/Example-App.git",
        topLevelOutput: String? = nil,
        currentBranchOutput: String = "main",
        statusOutput: String,
        cloneHandler: (() throws -> Void)? = nil
    ) {
        self.remoteOutput = remoteOutput
        self.topLevelOutput = topLevelOutput
        self.currentBranchOutput = currentBranchOutput
        self.statusOutput = statusOutput
        self.cloneHandler = cloneHandler
    }

    func run(_ arguments: [String], description: String) throws -> String {
        commands.append(arguments)
        if arguments.contains("rev-parse") {
            return topLevelOutput ?? arguments[1]
        }
        if arguments.contains("remote") {
            return remoteOutput
        }
        if arguments.contains("branch") {
            return currentBranchOutput
        }
        if arguments.contains("status") {
            return statusOutput
        }
        if arguments.first == "clone" {
            try cloneHandler?()
        }
        return ""
    }
}
