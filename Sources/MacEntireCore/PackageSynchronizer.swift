import Foundation

public struct PackageSyncResult: Equatable, Sendable {
    public let package: PackageDefinition
    public let errorMessage: String?

    public var succeeded: Bool {
        errorMessage == nil
    }

    public init(package: PackageDefinition, errorMessage: String? = nil) {
        self.package = package
        self.errorMessage = errorMessage
    }
}

public struct SynchronizationSummary: Equatable, Sendable {
    public let macEntireUpdated: Bool
    public let macEntireErrorMessage: String?
    public let packageListErrorMessage: String?
    public let packageResults: [PackageSyncResult]

    public init(
        macEntireUpdated: Bool = false,
        macEntireErrorMessage: String? = nil,
        packageListErrorMessage: String? = nil,
        packageResults: [PackageSyncResult]
    ) {
        self.macEntireUpdated = macEntireUpdated
        self.macEntireErrorMessage = macEntireErrorMessage
        self.packageListErrorMessage = packageListErrorMessage
        self.packageResults = packageResults
    }

    public var statusMessage: String {
        var parts: [String] = []

        if macEntireUpdated {
            parts.append("MacEntire updated — reinstall required")
        } else if let macEntireErrorMessage {
            parts.append("MacEntire update skipped: \(macEntireErrorMessage)")
        }

        if let packageListErrorMessage {
            parts.append("Package list: \(packageListErrorMessage)")
        } else {
            let failures = packageResults.filter { !$0.succeeded }
            if failures.isEmpty {
                parts.append("All packages are up to date")
            } else if failures.count == 1, let failure = failures.first {
                parts.append(
                    "\(failure.package.displayName): \(failure.errorMessage ?? "Sync failed")"
                )
            } else {
                parts.append("\(failures.count) packages could not be synced")
            }
        }

        return parts.joined(separator: "; ")
    }
}

public enum PackageSyncError: LocalizedError, Equatable {
    case destinationIsNotRepository(String)
    case remoteMismatch(expected: String, actual: String)
    case branchMismatch(repository: String, expected: String, actual: String)
    case checkoutChanged(String)
    case detachedHead(String)
    case localChanges(String)
    case missingLauncher(String)
    case macEntireIsNotRepository
    case commandFailed(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsNotRepository(let name):
            return "\(name) already exists but is not a Git repository."
        case .remoteMismatch(let expected, let actual):
            return "Origin is \(actual), expected \(expected)."
        case .branchMismatch(let repository, let expected, let actual):
            return "\(repository) is on branch \(actual), expected \(expected); update skipped."
        case .checkoutChanged(let name):
            return "\(name) changed while checking for updates; update skipped."
        case .detachedHead(let name):
            return "\(name) has a detached HEAD; update skipped."
        case .localChanges(let name):
            return "\(name) has local changes; update skipped."
        case .missingLauncher(let name):
            return "\(name) does not contain scripts/run-app.sh."
        case .macEntireIsNotRepository:
            return "The configured MacEntire root is not a Git repository."
        case .commandFailed(let command, let output):
            let detail = outputSummary(output)
            return "\(command) failed: \(detail.isEmpty ? "Git returned an error." : detail)"
        }
    }
}

public protocol GitRunning: Sendable {
    func run(_ arguments: [String], description: String) throws -> String
}

public struct ProcessGitRunner: GitRunning, Sendable {
    public init() {}

    public func run(_ arguments: [String], description: String) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw PackageSyncError.commandFailed(
                command: description,
                output: error.localizedDescription
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)

        guard process.terminationStatus == 0 else {
            throw PackageSyncError.commandFailed(command: description, output: output)
        }
        return output
    }
}

public final class PackageSynchronizer: @unchecked Sendable {
    public let workspace: PackageWorkspace
    private let gitRunner: any GitRunning

    public init(workspace: PackageWorkspace, gitRunner: any GitRunning = ProcessGitRunner()) {
        self.workspace = workspace
        self.gitRunner = gitRunner
    }

    public func synchronizeAll() -> SynchronizationSummary {
        let macEntireUpdated: Bool
        let macEntireErrorMessage: String?
        do {
            macEntireUpdated = try synchronizeMacEntire()
            macEntireErrorMessage = nil
        } catch {
            macEntireUpdated = false
            macEntireErrorMessage = error.localizedDescription
        }

        let definitions: [PackageDefinition]
        do {
            definitions = try workspace.definitions()
        } catch {
            return SynchronizationSummary(
                macEntireUpdated: macEntireUpdated,
                macEntireErrorMessage: macEntireErrorMessage,
                packageListErrorMessage: error.localizedDescription,
                packageResults: []
            )
        }

        let results = definitions.map { package in
            do {
                try synchronize(package)
                return PackageSyncResult(package: package)
            } catch {
                return PackageSyncResult(
                    package: package,
                    errorMessage: error.localizedDescription
                )
            }
        }

        return SynchronizationSummary(
            macEntireUpdated: macEntireUpdated,
            macEntireErrorMessage: macEntireErrorMessage,
            packageResults: results
        )
    }

    @discardableResult
    func synchronizeMacEntire() throws -> Bool {
        let root = workspace.rootDirectory
        let resolvedTopLevel = try gitRunner.run(
            ["-C", root.path, "rev-parse", "--show-toplevel"],
            description: "Validate MacEntire checkout"
        )
        guard samePath(root.path, resolvedTopLevel) else {
            throw PackageSyncError.macEntireIsNotRepository
        }

        try requireCleanCheckout(at: root, named: "MacEntire")

        let branch = try branchName(at: root, named: "MacEntire")
        let revision = try gitRunner.run(
            ["-C", root.path, "rev-parse", "HEAD"],
            description: "Read MacEntire revision"
        )

        _ = try gitRunner.run(
            ["-C", root.path, "fetch", "origin", "refs/heads/\(branch)"],
            description: "Fetch MacEntire"
        )

        try requireCleanCheckout(at: root, named: "MacEntire")
        let branchAfterFetch = try branchName(at: root, named: "MacEntire")
        guard branchAfterFetch == branch else {
            throw PackageSyncError.branchMismatch(
                repository: "MacEntire",
                expected: branch,
                actual: branchAfterFetch
            )
        }
        let revisionAfterFetch = try gitRunner.run(
            ["-C", root.path, "rev-parse", "HEAD"],
            description: "Revalidate MacEntire revision"
        )
        guard revisionAfterFetch == revision else {
            throw PackageSyncError.checkoutChanged("MacEntire")
        }

        _ = try gitRunner.run(
            ["-C", root.path, "merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"],
            description: "Update MacEntire"
        )
        let updatedRevision = try gitRunner.run(
            ["-C", root.path, "rev-parse", "HEAD"],
            description: "Read updated MacEntire revision"
        )
        return updatedRevision != revision
    }

    public func synchronize(_ package: PackageDefinition) throws {
        try FileManager.default.createDirectory(
            at: workspace.packagesDirectory,
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: package.directoryURL.path,
            isDirectory: &isDirectory
        ) {
            guard isDirectory.boolValue,
                  FileManager.default.fileExists(
                    atPath: package.directoryURL.appendingPathComponent(".git").path
                  ) else {
                throw PackageSyncError.destinationIsNotRepository(package.repositoryName)
            }

            let remote = try gitRunner.run(
                ["-C", package.directoryURL.path, "remote", "get-url", "origin"],
                description: "Read \(package.repositoryName) origin"
            )
            guard normalizedGitRemote(remote)
                == normalizedGitRemote(package.repositoryURL.absoluteString) else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remote)
                )
            }

            try requireCleanCheckout(at: package.directoryURL, named: package.repositoryName)
            let currentBranch = try branchName(
                at: package.directoryURL,
                named: package.repositoryName
            )
            if let expectedBranch = package.branch, currentBranch != expectedBranch {
                throw PackageSyncError.branchMismatch(
                    repository: package.repositoryName,
                    expected: expectedBranch,
                    actual: currentBranch
                )
            }

            let branch = package.branch ?? currentBranch
            _ = try gitRunner.run(
                [
                    "-C", package.directoryURL.path,
                    "fetch", "origin", "refs/heads/\(branch)"
                ],
                description: "Fetch \(package.repositoryName)"
            )

            try requireCleanCheckout(at: package.directoryURL, named: package.repositoryName)
            let branchAfterFetch = try branchName(
                at: package.directoryURL,
                named: package.repositoryName
            )
            guard branchAfterFetch == currentBranch else {
                throw PackageSyncError.branchMismatch(
                    repository: package.repositoryName,
                    expected: currentBranch,
                    actual: branchAfterFetch
                )
            }

            _ = try gitRunner.run(
                [
                    "-C", package.directoryURL.path,
                    "merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"
                ],
                description: "Update \(package.repositoryName)"
            )
        } else {
            var arguments = ["clone", "--origin", "origin"]
            if let branch = package.branch {
                arguments.append(contentsOf: ["--branch", branch, "--single-branch"])
            }
            arguments.append(contentsOf: [
                package.repositoryURL.absoluteString,
                package.directoryURL.path
            ])
            _ = try gitRunner.run(arguments, description: "Clone \(package.repositoryName)")
        }

        var launcherIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: package.launcherURL.path,
            isDirectory: &launcherIsDirectory
        ), !launcherIsDirectory.boolValue else {
            throw PackageSyncError.missingLauncher(package.repositoryName)
        }
    }

    private func requireCleanCheckout(at directory: URL, named name: String) throws {
        let changes = try gitRunner.run(
            ["-C", directory.path, "status", "--porcelain"],
            description: "Check \(name)"
        )
        guard changes.isEmpty else {
            throw PackageSyncError.localChanges(name)
        }
    }

    private func branchName(at directory: URL, named name: String) throws -> String {
        let branch = try gitRunner.run(
            ["-C", directory.path, "branch", "--show-current"],
            description: "Read \(name) branch"
        )
        guard !branch.isEmpty else {
            throw PackageSyncError.detachedHead(name)
        }
        return branch
    }
}

func normalizedGitRemote(_ value: String) -> String {
    var remote = redactedGitRemote(value)
    while remote.hasSuffix("/") {
        remote.removeLast()
    }
    if remote.lowercased().hasSuffix(".git") {
        remote.removeLast(4)
    }
    return remote.lowercased()
}

func redactedGitRemote(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed), components.scheme != nil else {
        return trimmed
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? "<redacted>"
}

private func samePath(_ lhs: String, _ rhs: String) -> Bool {
    URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
        == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
}

private func outputSummary(_ output: String) -> String {
    let singleLine = output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard singleLine.count > 300 else {
        return singleLine
    }
    return String(singleLine.prefix(299)) + "…"
}
