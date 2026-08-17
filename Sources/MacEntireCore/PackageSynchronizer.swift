import Darwin
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
    case symbolicLinkCheckout(String)
    case remoteMismatch(expected: String, actual: String)
    case branchMismatch(repository: String, expected: String, actual: String)
    case detachedHead(String)
    case localChanges(String)
    case missingLauncher(String)
    case commandFailed(command: String, output: String)
    case commandTimedOut(command: String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsNotRepository(let name):
            return "\(name) already exists but is not a Git repository."
        case .symbolicLinkCheckout(let name):
            return "\(name) checkout path is a symbolic link."
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
        case .commandTimedOut(let command):
            return "\(command) timed out; check the network and try again."
        }
    }
}

public protocol GitRunning: Sendable {
    func run(_ arguments: [String], description: String) throws -> String
}

public struct ProcessGitRunner: GitRunning, Sendable {
    public static let defaultTimeout: TimeInterval = 5 * 60
    static let maximumCapturedOutputBytes = 256 * 1024

    private let executableURL: URL
    private let timeout: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = defaultTimeout
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func run(_ arguments: [String], description: String) throws -> String {
        let outputPipe = Pipe()
        let output = BoundedProcessOutput(maximumBytes: Self.maximumCapturedOutputBytes)
        let readerFinished = DispatchSemaphore(value: 0)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                readerFinished.signal()
                return
            }
            output.append(data)
        }
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        }

        let process = Process()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.terminationHandler = { _ in
            termination.signal()
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw PackageSyncError.commandFailed(command: description, output: error.localizedDescription)
        }
        try? outputPipe.fileHandleForWriting.close()

        guard termination.wait(timeout: .now() + max(timeout, 0)) == .success else {
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
            throw PackageSyncError.commandTimedOut(command: description)
        }

        _ = readerFinished.wait(timeout: .now() + 1)
        let capturedOutput = output.string

        guard process.terminationStatus == 0 else {
            throw PackageSyncError.commandFailed(command: description, output: capturedOutput)
        }

        return capturedOutput
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }

        if newData.count >= maximumBytes {
            data = Data(newData.suffix(maximumBytes))
            return
        }

        let overflow = data.count + newData.count - maximumBytes
        if overflow > 0 {
            data.removeFirst(overflow)
        }
        data.append(newData)
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        guard !isSymbolicLink(at: package.directoryURL) else {
            throw PackageSyncError.symbolicLinkCheckout(package.repositoryName)
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: package.directoryURL.path, isDirectory: &isDirectory) {
            guard
                isDirectory.boolValue,
                FileManager.default.fileExists(atPath: package.directoryURL.appendingPathComponent(".git").path)
            else {
                throw PackageSyncError.destinationIsNotRepository(package.repositoryName)
            }

            let resolvedTopLevel = try gitRunner.run(
                ["-C", package.directoryURL.path, "rev-parse", "--show-toplevel"],
                description: "Validate \(package.repositoryName) checkout"
            )
            let resolvedTopLevelURL = URL(fileURLWithPath: resolvedTopLevel, isDirectory: true)
            guard resolvedCheckoutPath(resolvedTopLevelURL) == resolvedCheckoutPath(package.directoryURL) else {
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
                ["-C", package.directoryURL.path, "fetch", "origin", "refs/heads/\(branch)"],
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

            if let expectedBranch = package.branch {
                let currentBranch = try gitRunner.run(
                    ["-C", package.directoryURL.path, "branch", "--show-current"],
                    description: "Read \(package.repositoryName) branch"
                )
                guard !currentBranch.isEmpty else {
                    throw PackageSyncError.detachedHead(package.repositoryName)
                }
                guard currentBranch == expectedBranch else {
                    throw PackageSyncError.branchMismatch(
                        repository: package.repositoryName,
                        expected: expectedBranch,
                        actual: currentBranch
                    )
                }
            }
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
