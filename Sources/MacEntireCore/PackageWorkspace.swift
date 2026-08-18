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
    public private(set) var isTerminationDeferred = false

    public init() {}

    public mutating func beginSynchronization() {
        isSynchronizationInProgress = true
    }

    public mutating func requestTermination() -> Bool {
        guard isSynchronizationInProgress else {
            return true
        }
        isTerminationDeferred = true
        return false
    }

    public mutating func endSynchronization(
        allowDeferredTermination: Bool = true
    ) -> ApplicationTerminationResolution {
        isSynchronizationInProgress = false
        guard isTerminationDeferred else {
            return .noDeferredTermination
        }
        isTerminationDeferred = false
        return allowDeferredTermination
            ? .completeDeferredTermination
            : .cancelDeferredTermination
    }
}

public struct ManagedPackage: Identifiable, Equatable, Sendable {
    public let definition: PackageDefinition
    public let state: PackageState

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
        guard let contents = try? String(contentsOf: packageListURL, encoding: .utf8) else {
            throw PackageListError.unreadableFile(packageListURL.path)
        }

        return try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)
    }

    public func packages(
        fileManager: FileManager = .default,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) throws -> [ManagedPackage] {
        let definitions = try definitions()
        if isSymbolicLink(at: packagesDirectory, fileManager: fileManager) {
            let error = PackageSyncError.symbolicLinkPackagesDirectory
            return definitions.map { definition in
                ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }
        }

        return definitions.map { definition in
            guard !isSymbolicLink(at: definition.directoryURL, fileManager: fileManager) else {
                let error = PackageSyncError.symbolicLinkCheckout(definition.repositoryName)
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: definition.directoryURL.path, isDirectory: &isDirectory) else {
                return ManagedPackage(definition: definition, state: .notInstalled)
            }

            guard isDirectory.boolValue else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package path is not a directory")
                )
            }

            guard fileManager.fileExists(atPath: definition.directoryURL.appendingPathComponent(".git").path) else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package folder is not a Git repository")
                )
            }

            var launcherIsDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: definition.launcherURL.path, isDirectory: &launcherIsDirectory),
                !launcherIsDirectory.boolValue
            else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("Missing scripts/run-app.sh")
                )
            }
            guard fileManager.isExecutableFile(atPath: definition.launcherURL.path) else {
                let error = PackageSyncError.nonExecutableLauncher(definition.repositoryName)
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let resolvedTopLevel: String
            do {
                resolvedTopLevel = try gitRunner.run(
                    ["-C", definition.directoryURL.path, "rev-parse", "--show-toplevel"],
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
            guard resolvedCheckoutPath(resolvedTopLevelURL) == resolvedCheckoutPath(definition.directoryURL) else {
                let error = PackageSyncError.destinationIsNotRepository(definition.repositoryName)
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            let remote: String
            do {
                remote = try gitRunner.run(
                    ["-C", definition.directoryURL.path, "config", "--get", "remote.origin.url"],
                    description: "Read \(definition.repositoryName) origin"
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
                    ["-C", definition.directoryURL.path, "branch", "--show-current"],
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

            return ManagedPackage(definition: definition, state: .ready)
        }
    }
}

func isSymbolicLink(at url: URL, fileManager: FileManager = .default) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
}

func resolvedCheckoutPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}
