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

public enum PackageSyncError: LocalizedError, Equatable {
    case destinationIsNotRepository(String)
    case remoteMismatch(expected: String, actual: String)
    case branchMismatch(repository: String, expected: String, actual: String)
    case detachedHead(String)
    case localChanges(String)
    case missingLauncher(String)
    case commandFailed(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsNotRepository(let name):
            return "\(name) already exists but is not a Git repository."
        case .remoteMismatch(let expected, let actual):
            return "Origin is \(actual), expected \(expected)."
        case .branchMismatch(let repository, let expected, let actual):
            return "\(repository) is on branch \(actual), expected \(expected); update skipped."
        case .detachedHead(let name):
            return "\(name) has a detached HEAD; update skipped."
        case .localChanges(let name):
            return "\(name) has local changes; update skipped."
        case .missingLauncher(let name):
            return "\(name) does not contain scripts/run-app.sh."
        case .commandFailed(let command, let output):
            let detail = output.isEmpty ? "Git returned an error." : output
            return "\(command) failed: \(detail)"
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
            throw PackageSyncError.commandFailed(command: description, output: error.localizedDescription)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

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

    public func synchronizeAll() throws -> [PackageSyncResult] {
        try workspace.definitions().map { package in
            do {
                try synchronize(package)
                return PackageSyncResult(package: package)
            } catch {
                return PackageSyncResult(package: package, errorMessage: error.localizedDescription)
            }
        }
    }

    public func synchronize(_ package: PackageDefinition) throws {
        try FileManager.default.createDirectory(
            at: workspace.packagesDirectory,
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: package.directoryURL.path, isDirectory: &isDirectory) {
            guard
                isDirectory.boolValue,
                FileManager.default.fileExists(atPath: package.directoryURL.appendingPathComponent(".git").path)
            else {
                throw PackageSyncError.destinationIsNotRepository(package.repositoryName)
            }

            let remote = try gitRunner.run(
                ["-C", package.directoryURL.path, "remote", "get-url", "origin"],
                description: "Read \(package.repositoryName) origin"
            )
            guard normalizedGitRemote(remote) == normalizedGitRemote(package.repositoryURL.absoluteString) else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: remote.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            let changes = try gitRunner.run(
                ["-C", package.directoryURL.path, "status", "--porcelain"],
                description: "Check \(package.repositoryName)"
            )
            guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PackageSyncError.localChanges(package.repositoryName)
            }

            let currentBranch = try gitRunner.run(
                ["-C", package.directoryURL.path, "branch", "--show-current"],
                description: "Read \(package.repositoryName) branch"
            )
            guard !currentBranch.isEmpty else {
                throw PackageSyncError.detachedHead(package.repositoryName)
            }

            if let expectedBranch = package.branch {
                guard currentBranch == expectedBranch else {
                    throw PackageSyncError.branchMismatch(
                        repository: package.repositoryName,
                        expected: expectedBranch,
                        actual: currentBranch
                    )
                }
            }

            let branch = package.branch ?? currentBranch
            _ = try gitRunner.run(
                ["-C", package.directoryURL.path, "fetch", "origin", branch],
                description: "Fetch \(package.repositoryName)"
            )
            _ = try gitRunner.run(
                [
                    "-C", package.directoryURL.path,
                    "merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"
                ],
                description: "Update \(package.repositoryName)"
            )
        } else {
            var cloneArguments = ["clone", "--origin", "origin"]
            if let branch = package.branch {
                cloneArguments.append(contentsOf: ["--branch", branch, "--single-branch"])
            }
            cloneArguments.append(contentsOf: [package.repositoryURL.absoluteString, package.directoryURL.path])
            _ = try gitRunner.run(
                cloneArguments,
                description: "Clone \(package.repositoryName)"
            )
        }

        var launcherIsDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: package.launcherURL.path, isDirectory: &launcherIsDirectory),
            !launcherIsDirectory.boolValue
        else {
            throw PackageSyncError.missingLauncher(package.repositoryName)
        }
    }
}

func normalizedGitRemote(_ value: String) -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    if normalized.lowercased().hasSuffix(".git") {
        normalized.removeLast(4)
    }
    return normalized.lowercased()
}
