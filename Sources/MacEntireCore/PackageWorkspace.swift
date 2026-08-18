import Foundation

public enum PackageState: Equatable, Sendable {
    case notInstalled
    case ready
    case unavailable(String)
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
}

public struct PackageWorkspace: Sendable {
    public let rootDirectory: URL
    public let packageListURL: URL
    public let ignoreListURL: URL
    public let packagesDirectory: URL

    public init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        let packagesDirectory = root.appendingPathComponent("Packages", isDirectory: true)
        self.rootDirectory = root
        self.packagesDirectory = packagesDirectory
        self.packageListURL = packagesDirectory.appendingPathComponent(
            PackageListParser.packageListFilename,
            isDirectory: false
        )
        self.ignoreListURL = packagesDirectory.appendingPathComponent(
            PackageListParser.ignoreListFilename,
            isDirectory: false
        )
    }

    public func definitions(fileManager: FileManager = .default) throws -> [PackageDefinition] {
        let parser = PackageListParser()
        let configured = try parser.parse(
            contents(of: packageListURL),
            packagesDirectory: packagesDirectory
        )

        guard fileManager.fileExists(atPath: ignoreListURL.path) else {
            return configured
        }

        let ignoredRepositories = Set(try parser.parse(
            contents(of: ignoreListURL),
            packagesDirectory: packagesDirectory,
            enforceUniqueDirectoryNames: false
        ).map { normalizedGitRemote($0.repositoryURL.absoluteString) })

        return configured.filter {
            !ignoredRepositories.contains(
                normalizedGitRemote($0.repositoryURL.absoluteString)
            )
        }
    }

    public func packages(
        fileManager: FileManager = .default,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) throws -> [ManagedPackage] {
        try definitions(fileManager: fileManager).map { definition in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: definition.directoryURL.path,
                isDirectory: &isDirectory
            ) else {
                return ManagedPackage(definition: definition, state: .notInstalled)
            }
            guard isDirectory.boolValue,
                  fileManager.fileExists(
                    atPath: definition.directoryURL.appendingPathComponent(".git").path
                  ) else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package folder is not a Git repository")
                )
            }

            var launcherIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: definition.launcherURL.path,
                isDirectory: &launcherIsDirectory
            ), !launcherIsDirectory.boolValue else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("Missing scripts/run-app.sh")
                )
            }

            do {
                let remote = try gitRunner.run(
                    ["-C", definition.directoryURL.path, "remote", "get-url", "origin"],
                    description: "Read \(definition.repositoryName) origin"
                )
                guard normalizedGitRemote(remote)
                    == normalizedGitRemote(definition.repositoryURL.absoluteString) else {
                    throw PackageSyncError.remoteMismatch(
                        expected: definition.repositoryURL.absoluteString,
                        actual: redactedGitRemote(remote)
                    )
                }

                let branch = try gitRunner.run(
                    ["-C", definition.directoryURL.path, "branch", "--show-current"],
                    description: "Read \(definition.repositoryName) branch"
                )
                guard !branch.isEmpty else {
                    throw PackageSyncError.detachedHead(definition.repositoryName)
                }
                if let expectedBranch = definition.branch, branch != expectedBranch {
                    throw PackageSyncError.branchMismatch(
                        repository: definition.repositoryName,
                        expected: expectedBranch,
                        actual: branch
                    )
                }
            } catch {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable(error.localizedDescription)
                )
            }

            return ManagedPackage(definition: definition, state: .ready)
        }
    }

    private func contents(of url: URL) throws -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw PackageListError.unreadableFile(url.path)
        }
        return contents
    }
}
