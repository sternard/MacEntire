import Foundation

public enum PackageState: Equatable, Sendable {
    case notInstalled
    case ready
    case unavailable(String)
}

public struct PackageOperationState: Equatable, Sendable {
    public private(set) var isSynchronizing = false
    public private(set) var activePackageIdentifiers: Set<String> = []

    public var activeLauncherCount: Int {
        activePackageIdentifiers.count
    }

    public var canSynchronize: Bool {
        !isSynchronizing && activeLauncherCount == 0
    }

    public init() {}

    public mutating func beginSynchronization() -> Bool {
        guard canSynchronize else {
            return false
        }
        isSynchronizing = true
        return true
    }

    public mutating func endSynchronization() {
        isSynchronizing = false
    }

    public mutating func beginLaunch(packageIdentifier: String) -> Bool {
        guard
            !isSynchronizing,
            activePackageIdentifiers.insert(packageIdentifier).inserted
        else {
            return false
        }
        return true
    }

    public mutating func endLaunch(packageIdentifier: String) {
        activePackageIdentifiers.remove(packageIdentifier)
    }

    public func isLaunching(packageIdentifier: String) -> Bool {
        activePackageIdentifiers.contains(packageIdentifier)
    }
}

public enum ApplicationTerminationResolution: Equatable, Sendable {
    case noDeferredTermination
    case completeDeferredTermination
    case cancelDeferredTermination
}

public struct ApplicationTerminationState: Equatable, Sendable {
    public private(set) var isSynchronizationInProgress = false
    public private(set) var activeLauncherCount = 0
    public private(set) var isTerminationDeferred = false

    public init() {}

    public mutating func beginSynchronization() {
        isSynchronizationInProgress = true
    }

    public mutating func beginLaunch() {
        activeLauncherCount += 1
    }

    public mutating func requestTermination() -> Bool {
        guard isSynchronizationInProgress || activeLauncherCount > 0 else {
            return true
        }
        isTerminationDeferred = true
        return false
    }

    public mutating func endSynchronization(
        allowDeferredTermination: Bool = true
    ) -> ApplicationTerminationResolution {
        isSynchronizationInProgress = false
        if isTerminationDeferred, !allowDeferredTermination {
            isTerminationDeferred = false
            return .cancelDeferredTermination
        }
        return resolveDeferredTerminationIfIdle()
    }

    public mutating func endLaunch() -> ApplicationTerminationResolution {
        guard activeLauncherCount > 0 else {
            return .noDeferredTermination
        }
        activeLauncherCount -= 1
        return resolveDeferredTerminationIfIdle()
    }

    private mutating func resolveDeferredTerminationIfIdle() -> ApplicationTerminationResolution {
        guard !isSynchronizationInProgress, activeLauncherCount == 0 else {
            return .noDeferredTermination
        }
        guard isTerminationDeferred else {
            return .noDeferredTermination
        }
        isTerminationDeferred = false
        return .completeDeferredTermination
    }
}

public struct ManagedPackage: Identifiable, Equatable, Sendable {
    public let definition: PackageDefinition
    public let state: PackageState
    let packagesDirectoryHandle: StableDirectoryHandle?
    let checkoutDirectoryHandle: StableDirectoryHandle?

    public var id: String {
        definition.id
    }

    public var displayTitle: String {
        switch state {
        case .ready:
            return definition.displayName
        case .notInstalled:
            return "\(definition.displayName) — Not installed"
        case .unavailable(let reason):
            return "\(definition.displayName) — Unavailable: \(reason)"
        }
    }

    public init(definition: PackageDefinition, state: PackageState) {
        self.definition = definition
        self.state = state
        packagesDirectoryHandle = nil
        checkoutDirectoryHandle = nil
    }

    init(
        definition: PackageDefinition,
        state: PackageState,
        packagesDirectoryHandle: StableDirectoryHandle,
        checkoutDirectoryHandle: StableDirectoryHandle
    ) {
        self.definition = definition
        self.state = state
        self.packagesDirectoryHandle = packagesDirectoryHandle
        self.checkoutDirectoryHandle = checkoutDirectoryHandle
    }

    var launchDirectoryURL: URL {
        checkoutDirectoryHandle?.url ?? definition.directoryURL
    }

    var launcherURL: URL {
        launchDirectoryURL.appendingPathComponent("scripts/run-app.sh", isDirectory: false)
    }

    public static func == (lhs: ManagedPackage, rhs: ManagedPackage) -> Bool {
        lhs.definition == rhs.definition && lhs.state == rhs.state
    }

    public func isLaunchEnabled(
        whileSynchronizing isSynchronizing: Bool,
        whilePackageIsLaunching isPackageLaunching: Bool
    ) -> Bool {
        state == .ready && !isSynchronizing && !isPackageLaunching
    }
}

public func refreshedPackageCatalogStatusMessage(
    currentMessage: String?,
    packagesAreEmpty: Bool,
    currentMessageIsInspectionError: Bool = false,
    fallbackMessage: String? = nil
) -> String? {
    let currentMessage = currentMessageIsInspectionError ? fallbackMessage : currentMessage
    if packagesAreEmpty {
        return currentMessage ?? "No packages configured"
    }
    return currentMessage == "No packages configured" ? nil : currentMessage
}

public struct PackageWorkspace: Sendable {
    public let rootDirectory: URL
    public let packageListURL: URL
    public let packagesDirectory: URL

    public init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        let packagesDirectory = root.appendingPathComponent("Packages", isDirectory: true)
        self.rootDirectory = root
        self.packageListURL = packagesDirectory.appendingPathComponent(
            PackageListParser.packageListFilename,
            isDirectory: false
        )
        self.packagesDirectory = packagesDirectory
    }

    public func definitions() throws -> [PackageDefinition] {
        try definitions(packageListURL: packageListURL)
    }

    public func packages(
        fileManager: FileManager = .default,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) throws -> [ManagedPackage] {
        if isSymbolicLink(at: packagesDirectory, fileManager: fileManager) {
            let definitions = try definitions()
            let error = PackageSyncError.symbolicLinkPackagesDirectory
            return definitions.map { definition in
                ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }
        }

        let packagesDirectoryHandle = try openManagedPackagesDirectory(
            rootDirectory: rootDirectory
        )
        let stablePackageListURL = packagesDirectoryHandle.url.appendingPathComponent(
            PackageListParser.packageListFilename,
            isDirectory: false
        )
        let definitions = try definitions(packageListURL: stablePackageListURL)

        return definitions.map { definition in
            let checkoutDirectoryHandle: StableDirectoryHandle
            do {
                guard let openedCheckout = try openManagedCheckout(
                    named: definition.repositoryName,
                    in: packagesDirectoryHandle
                ) else {
                    return ManagedPackage(definition: definition, state: .notInstalled)
                }
                checkoutDirectoryHandle = openedCheckout
            } catch {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }
            let checkoutDirectory = checkoutDirectoryHandle.url

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: checkoutDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package path is not a directory")
                )
            }

            guard fileManager.fileExists(atPath: checkoutDirectory.appendingPathComponent(".git").path) else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package folder is not a Git repository")
                )
            }

            var launcherIsDirectory: ObjCBool = false
            let launcherURL = checkoutDirectory.appendingPathComponent("scripts/run-app.sh")
            guard
                fileManager.fileExists(atPath: launcherURL.path, isDirectory: &launcherIsDirectory),
                !launcherIsDirectory.boolValue
            else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("Missing scripts/run-app.sh")
                )
            }
            guard fileManager.isExecutableFile(atPath: launcherURL.path) else {
                let error = PackageSyncError.nonExecutableLauncher(definition.repositoryName)
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let resolvedTopLevel: String
            do {
                resolvedTopLevel = try gitRunner.run(
                    ["-C", checkoutDirectory.path, "rev-parse", "--show-toplevel"],
                    description: "Validate \(definition.repositoryName) checkout"
                )
            } catch {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let resolvedTopLevelURL = URL(
                fileURLWithPath: resolvedTopLevel,
                isDirectory: true
            )
            guard checkoutDirectoryHandle.matches(resolvedTopLevelURL) else {
                let error = PackageSyncError.destinationIsNotRepository(definition.repositoryName)
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let remoteOutput: String
            do {
                remoteOutput = try gitRunner.run(
                    ["-C", checkoutDirectory.path, "config", "--get-all", "remote.origin.url"],
                    description: "Read \(definition.repositoryName) origin"
                )
            } catch {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let remote: String
            do {
                remote = try singleStoredGitRemote(
                    remoteOutput,
                    expected: definition.repositoryURL.absoluteString
                )
            } catch {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            guard normalizedGitRemote(remote) == normalizedGitRemote(definition.repositoryURL.absoluteString) else {
                let error = PackageSyncError.remoteMismatch(
                    expected: definition.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remote)
                )
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let currentBranch: String
            do {
                currentBranch = try gitRunner.run(
                    ["-C", checkoutDirectory.path, "branch", "--show-current"],
                    description: "Read \(definition.repositoryName) branch"
                )
            } catch {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            guard !currentBranch.isEmpty else {
                let error = PackageSyncError.detachedHead(definition.repositoryName)
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            if let expectedBranch = definition.branch {
                guard currentBranch == expectedBranch else {
                    let error = PackageSyncError.branchMismatch(
                        repository: definition.repositoryName,
                        expected: expectedBranch,
                        actual: currentBranch
                    )
                    return ManagedPackage(
                        definition: definition,
                        state: .unavailable(error.localizedDescription)
                    )
                }
            }

            guard managedPackagesDirectoryIsCurrent(
                packagesDirectoryHandle,
                at: packagesDirectory
            ) else {
                let error = PackageSyncError.symbolicLinkPackagesDirectory
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let visibleCheckout = packagesDirectoryHandle.url.appendingPathComponent(
                definition.repositoryName,
                isDirectory: true
            )
            guard checkoutDirectoryHandle.matches(visibleCheckout) else {
                let error = PackageSyncError.destinationIsNotRepository(
                    definition.repositoryName
                )
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            return ManagedPackage(
                definition: definition,
                state: .ready,
                packagesDirectoryHandle: packagesDirectoryHandle,
                checkoutDirectoryHandle: checkoutDirectoryHandle
            )
        }
    }

    private func definitions(packageListURL: URL) throws -> [PackageDefinition] {
        guard let contents = try? String(contentsOf: packageListURL, encoding: .utf8) else {
            throw PackageListError.unreadableFile(packageListURL.path)
        }

        return try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)
    }
}

func isSymbolicLink(at url: URL, fileManager: FileManager = .default) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
}

func resolvedCheckoutPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}
