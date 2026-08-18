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

public struct SynchronizationSummary: Equatable, Sendable {
    public let macEntireErrorMessage: String?
    public let macEntireRequiresReinstallation: Bool
    public let packageListErrorMessage: String?
    public let packageResults: [PackageSyncResult]

    public init(
        macEntireErrorMessage: String? = nil,
        macEntireRequiresReinstallation: Bool = false,
        packageListErrorMessage: String? = nil,
        packageResults: [PackageSyncResult]
    ) {
        self.macEntireErrorMessage = macEntireErrorMessage
        self.macEntireRequiresReinstallation = macEntireRequiresReinstallation
        self.packageListErrorMessage = packageListErrorMessage
        self.packageResults = packageResults
    }

    public var statusMessage: String {
        let failures = packageResults.filter { !$0.succeeded }
        if let macEntireErrorMessage, macEntireRequiresReinstallation {
            var statusParts = [
                "MacEntire updated — reinstall required",
                macEntireErrorMessage
            ]
            if let packageListErrorMessage {
                statusParts.append("Package list: \(packageListErrorMessage)")
            }
            if !failures.isEmpty {
                statusParts.append("\(failures.count) package updates could not be synced")
            }
            return statusParts.joined(separator: "; ")
        }
        if let macEntireErrorMessage {
            if let packageListErrorMessage {
                return "MacEntire: \(macEntireErrorMessage); Package list: \(packageListErrorMessage)"
            }
            if failures.isEmpty {
                return "MacEntire: \(macEntireErrorMessage)"
            }
            return "MacEntire and \(failures.count) package updates could not be synced"
        }
        if macEntireRequiresReinstallation {
            if let packageListErrorMessage {
                return "MacEntire updated — quit and run scripts/install-app.sh to install it; "
                    + "Package list: \(packageListErrorMessage)"
            }
            if failures.isEmpty {
                return "MacEntire updated — quit and run scripts/install-app.sh to install it"
            }
            return "MacEntire updated — reinstall required; \(failures.count) package updates could not be synced"
        }
        if let packageListErrorMessage {
            return "Package list: \(packageListErrorMessage)"
        }
        if failures.isEmpty {
            return "MacEntire and all packages are up to date"
        }
        if failures.count == 1, let failure = failures.first {
            return "\(failure.package.displayName): \(failure.errorMessage ?? "Sync failed")"
        }
        return "\(failures.count) packages could not be synced"
    }
}

public enum PackageSyncError: LocalizedError, Equatable {
    static let maximumDisplayedOutputCharacters = 200

    case destinationIsNotRepository(String)
    case symbolicLinkCheckout(String)
    case symbolicLinkPackagesDirectory
    case remoteMismatch(expected: String, actual: String)
    case branchMismatch(repository: String, expected: String, actual: String)
    case detachedHead(String)
    case localChanges(String)
    case missingLauncher(String)
    case nonExecutableLauncher(String)
    case macEntireIsNotRepository
    case packageListRecoveryRequired(reason: String, location: String)
    case packageListRestorationFailed(String, requiresReinstallation: Bool)
    case commandFailed(command: String, output: String)
    case commandTimedOut(command: String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsNotRepository(let name):
            return "\(name) already exists but is not a Git repository."
        case .symbolicLinkCheckout(let name):
            return "\(name) checkout path is a symbolic link."
        case .symbolicLinkPackagesDirectory:
            return "The Packages directory is a symbolic link."
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
        case .nonExecutableLauncher(let name):
            return "\(name) scripts/run-app.sh is not executable."
        case .macEntireIsNotRepository:
            return "The configured MacEntire root is not the root of a Git repository."
        case .packageListRecoveryRequired(let reason, let location):
            return "\(reason) Original package-list changes were saved to \(location)."
        case .packageListRestorationFailed(let detail, _):
            return "Could not restore Packages/packages.txt after updating MacEntire: \(detail)"
        case .commandFailed(let command, let output):
            let summary = Self.displayedOutputSummary(output)
            let detail = summary.isEmpty ? "Git returned an error." : summary
            return "\(command) failed: \(detail)"
        case .commandTimedOut(let command):
            return "\(command) timed out; check the network and try again."
        }
    }

    private static func displayedOutputSummary(_ output: String) -> String {
        let singleLine = output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard singleLine.count > maximumDisplayedOutputCharacters else {
            return singleLine
        }
        return String(singleLine.prefix(maximumDisplayedOutputCharacters - 1)) + "…"
    }

    var requiresReinstallation: Bool {
        switch self {
        case .packageListRestorationFailed(_, let requiresReinstallation):
            return requiresReinstallation
        default:
            return false
        }
    }
}

public protocol GitRunning: Sendable {
    func run(_ arguments: [String], description: String) throws -> String
}

public struct ProcessGitRunner: GitRunning, Sendable {
    public static let defaultTimeout: TimeInterval = 5 * 60
    static let maximumCapturedOutputBytes = 256 * 1024
    static let defaultOutputDrainTimeout: TimeInterval = 5

    private let executableURL: URL
    private let timeout: TimeInterval
    private let standardOutputDrainDelay: TimeInterval
    private let outputDrainTimeout: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = defaultTimeout
    ) {
        self.init(
            executableURL: executableURL,
            timeout: timeout,
            standardOutputDrainDelay: 0,
            outputDrainTimeout: Self.defaultOutputDrainTimeout
        )
    }

    init(
        executableURL: URL,
        timeout: TimeInterval,
        standardOutputDrainDelay: TimeInterval,
        outputDrainTimeout: TimeInterval = Self.defaultOutputDrainTimeout
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.standardOutputDrainDelay = standardOutputDrainDelay
        self.outputDrainTimeout = outputDrainTimeout
    }

    public func run(_ arguments: [String], description: String) throws -> String {
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardOutput = BoundedProcessOutput(maximumBytes: Self.maximumCapturedOutputBytes)
        let standardError = BoundedProcessOutput(maximumBytes: Self.maximumCapturedOutputBytes)
        let standardOutputFinished = DispatchSemaphore(value: 0)
        let standardErrorFinished = DispatchSemaphore(value: 0)
        let standardOutputDelay = OneShotDelay(standardOutputDrainDelay)
        standardOutputPipe.fileHandleForReading.readabilityHandler = { handle in
            standardOutputDelay.waitIfNeeded()
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                standardOutputFinished.signal()
                return
            }
            standardOutput.append(data)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                standardErrorFinished.signal()
                return
            }
            standardError.append(data)
        }
        defer {
            standardOutputPipe.fileHandleForReading.readabilityHandler = nil
            standardErrorPipe.fileHandleForReading.readabilityHandler = nil
            try? standardOutputPipe.fileHandleForReading.close()
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForReading.close()
            try? standardErrorPipe.fileHandleForWriting.close()
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let processIdentifier: pid_t
        do {
            processIdentifier = try spawnProcessGroup(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                standardOutputPipe: standardOutputPipe,
                standardErrorPipe: standardErrorPipe
            )
        } catch {
            throw PackageSyncError.commandFailed(command: description, output: error.localizedDescription)
        }
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()

        guard let waitStatus = waitForProcess(processIdentifier, timeout: max(timeout, 0)) else {
            _ = Darwin.kill(-processIdentifier, SIGTERM)
            let terminatedStatus = waitForProcess(processIdentifier, timeout: 1)
            _ = Darwin.kill(-processIdentifier, SIGKILL)
            if terminatedStatus == nil {
                _ = waitForProcess(processIdentifier, timeout: 1)
            }
            throw PackageSyncError.commandTimedOut(command: description)
        }

        let outputDrainDeadline = DispatchTime.now() + max(outputDrainTimeout, 0)
        let standardOutputDidFinish = standardOutputFinished.wait(
            timeout: outputDrainDeadline
        ) == .success
        let standardErrorDidFinish = standardErrorFinished.wait(
            timeout: outputDrainDeadline
        ) == .success
        guard standardOutputDidFinish, standardErrorDidFinish else {
            _ = Darwin.kill(-processIdentifier, SIGTERM)
            let terminationDeadline = DispatchTime.now() + 1
            if !standardOutputDidFinish {
                _ = standardOutputFinished.wait(timeout: terminationDeadline)
            }
            if !standardErrorDidFinish {
                _ = standardErrorFinished.wait(timeout: terminationDeadline)
            }
            _ = Darwin.kill(-processIdentifier, SIGKILL)
            throw PackageSyncError.commandTimedOut(command: description)
        }
        let capturedStandardOutput = standardOutput.string

        guard processExitCode(waitStatus) == 0 else {
            throw PackageSyncError.commandFailed(
                command: description,
                output: combinedProcessOutput(
                    standardOutput: capturedStandardOutput,
                    standardError: standardError.string,
                    maximumBytes: Self.maximumCapturedOutputBytes
                )
            )
        }

        return capturedStandardOutput
    }
}

private final class OneShotDelay: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: TimeInterval

    init(_ duration: TimeInterval) {
        self.duration = duration
    }

    func waitIfNeeded() {
        lock.lock()
        let duration = duration
        self.duration = 0
        lock.unlock()
        if duration > 0 {
            Thread.sleep(forTimeInterval: duration)
        }
    }
}

private func spawnProcessGroup(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    standardOutputPipe: Pipe,
    standardErrorPipe: Pipe
) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    let fileActionsResult = posix_spawn_file_actions_init(&fileActions)
    guard fileActionsResult == 0 else {
        throw posixError(fileActionsResult)
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let standardOutputDescriptor = standardOutputPipe.fileHandleForWriting.fileDescriptor
    let standardOutputReadDescriptor = standardOutputPipe.fileHandleForReading.fileDescriptor
    let standardErrorDescriptor = standardErrorPipe.fileHandleForWriting.fileDescriptor
    let standardErrorReadDescriptor = standardErrorPipe.fileHandleForReading.fileDescriptor
    for result in [
        posix_spawn_file_actions_adddup2(&fileActions, standardOutputDescriptor, STDOUT_FILENO),
        posix_spawn_file_actions_adddup2(&fileActions, standardErrorDescriptor, STDERR_FILENO),
        posix_spawn_file_actions_addclose(&fileActions, standardOutputReadDescriptor),
        posix_spawn_file_actions_addclose(&fileActions, standardErrorReadDescriptor),
        posix_spawn_file_actions_addclose(&fileActions, standardOutputDescriptor),
        posix_spawn_file_actions_addclose(&fileActions, standardErrorDescriptor)
    ] {
        guard result == 0 else {
            throw posixError(result)
        }
    }

    let attributesResult = posix_spawnattr_init(&attributes)
    guard attributesResult == 0 else {
        throw posixError(attributesResult)
    }
    defer { posix_spawnattr_destroy(&attributes) }

    let flagsResult = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    guard flagsResult == 0 else {
        throw posixError(flagsResult)
    }
    let processGroupResult = posix_spawnattr_setpgroup(&attributes, 0)
    guard processGroupResult == 0 else {
        throw posixError(processGroupResult)
    }

    let argumentStrings = [executableURL.path] + arguments
    let environmentStrings = environment
        .map { "\($0.key)=\($0.value)" }
        .sorted()
    var processIdentifier: pid_t = 0
    let spawnResult = withMutableCStringArray(argumentStrings) { argumentPointers in
        withMutableCStringArray(environmentStrings) { environmentPointers in
            executableURL.path.withCString { executablePath in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
    }
    guard spawnResult == 0 else {
        throw posixError(spawnResult)
    }
    return processIdentifier
}

private func withMutableCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}

private func waitForProcess(_ processIdentifier: pid_t, timeout: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        var status: Int32 = 0
        let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
            return status
        }
        if result == -1, errno != EINTR {
            return nil
        }
        if Date() >= deadline {
            return nil
        }
        usleep(10_000)
    } while true
}

private func processExitCode(_ waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    if signal == 0 {
        return (waitStatus >> 8) & 0xff
    }
    return 128 + signal
}

private func posixError(_ code: Int32) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
    )
}

private func combinedProcessOutput(
    standardOutput: String,
    standardError: String,
    maximumBytes: Int
) -> String {
    let output = [standardOutput, standardError]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    let data = Data(output.utf8)
    guard data.count > maximumBytes else {
        return output
    }
    return String(decoding: data.suffix(maximumBytes), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

final class BoundedProcessOutput: @unchecked Sendable {
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
        var output = String(decoding: data, as: UTF8.self)
        if output.last == "\n" {
            output.removeLast()
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

    public func synchronizeAll() throws -> SynchronizationSummary {
        let macEntireErrorMessage: String?
        let macEntireSyncError: PackageSyncError?
        let macEntireRequiresReinstallation: Bool
        do {
            macEntireRequiresReinstallation = try synchronizeMacEntire()
            macEntireErrorMessage = nil
            macEntireSyncError = nil
        } catch {
            macEntireSyncError = error as? PackageSyncError
            macEntireRequiresReinstallation = macEntireSyncError?.requiresReinstallation ?? false
            macEntireErrorMessage = error.localizedDescription
        }

        let definitions: [PackageDefinition]
        let packageListErrorMessage: String?
        if case .packageListRecoveryRequired = macEntireSyncError {
            definitions = []
            packageListErrorMessage = nil
        } else {
            do {
                definitions = try workspace.definitions()
                packageListErrorMessage = nil
            } catch {
                definitions = []
                packageListErrorMessage = error.localizedDescription
            }
        }

        let packageResults = definitions.map { package in
            do {
                try synchronize(package)
                return PackageSyncResult(package: package)
            } catch {
                return PackageSyncResult(package: package, errorMessage: error.localizedDescription)
            }
        }

        return SynchronizationSummary(
            macEntireErrorMessage: macEntireErrorMessage,
            macEntireRequiresReinstallation: macEntireRequiresReinstallation,
            packageListErrorMessage: packageListErrorMessage,
            packageResults: packageResults
        )
    }

    @discardableResult
    func synchronizeMacEntire() throws -> Bool {
        guard !isSymbolicLink(at: workspace.packagesDirectory) else {
            throw PackageSyncError.symbolicLinkPackagesDirectory
        }

        let rootDirectory = workspace.rootDirectory
        let resolvedTopLevel = try gitRunner.run(
            ["-C", rootDirectory.path, "rev-parse", "--show-toplevel"],
            description: "Validate MacEntire checkout"
        )
        let resolvedTopLevelURL = URL(fileURLWithPath: resolvedTopLevel, isDirectory: true)
        guard resolvedCheckoutPath(resolvedTopLevelURL) == resolvedCheckoutPath(rootDirectory) else {
            throw PackageSyncError.macEntireIsNotRepository
        }
        let originalBranch = try gitRunner.run(
            ["-C", rootDirectory.path, "branch", "--show-current"],
            description: "Read MacEntire branch"
        )
        guard !originalBranch.isEmpty else {
            throw PackageSyncError.detachedHead("MacEntire")
        }
        let originalRevision = try gitRunner.run(
            ["-C", rootDirectory.path, "rev-parse", "HEAD"],
            description: "Read current MacEntire revision"
        )
        let packageListIndexPath = try gitRunner.run(
            ["-C", rootDirectory.path, "rev-parse", "--git-path", "index"],
            description: "Locate MacEntire index"
        )
        let packageListIndexURL = URL(
            fileURLWithPath: packageListIndexPath,
            relativeTo: rootDirectory
        ).standardizedFileURL

        let fileManager = FileManager.default
        let preservedPackageListLinkDestination = try? fileManager.destinationOfSymbolicLink(
            atPath: workspace.packageListURL.path
        )
        let preservedPackageListPermissions: NSNumber?
        if preservedPackageListLinkDestination == nil {
            let attributes = try fileManager.attributesOfItem(atPath: workspace.packageListURL.path)
            preservedPackageListPermissions = attributes[.posixPermissions] as? NSNumber
        } else {
            preservedPackageListPermissions = nil
        }
        let preservedPackageList: Data
        do {
            preservedPackageList = try Data(contentsOf: workspace.packageListURL)
        } catch {
            throw PackageListError.unreadableFile(workspace.packageListURL.path)
        }

        let packageListPath = "Packages/\(PackageListParser.packageListFilename)"
        let preservedIndexEntry = try packageListIndexEntry(
            from: gitRunner.run(
                ["-C", rootDirectory.path, "ls-files", "--stage", "--", packageListPath],
                description: "Preserve MacEntire package list index"
            )
        )
        let headIndexEntry = packageListTreeEntry(
            from: try gitRunner.run(
                ["-C", rootDirectory.path, "ls-tree", "HEAD", "--", packageListPath],
                description: "Read committed MacEntire package list"
            )
        )
        let packageListHadStagedChanges = preservedIndexEntry != headIndexEntry
        let packageListRecovery: PackageListRecoverySnapshot
        do {
            packageListRecovery = try createPackageListRecovery(
                rootDirectory: rootDirectory,
                gitDirectory: packageListIndexURL.deletingLastPathComponent(),
                originalBranch: originalBranch,
                preservedPackageList: preservedPackageList,
                symbolicLinkDestination: preservedPackageListLinkDestination,
                indexWasCustomized: packageListHadStagedChanges,
                preservedIndexEntry: preservedIndexEntry,
                packageListPath: packageListPath,
                fileManager: fileManager
            )
        } catch {
            throw PackageSyncError.packageListRestorationFailed(
                "Could not create a recovery copy before updating: \(error.localizedDescription)",
                requiresReinstallation: false
            )
        }
        var preservePostFetchCheckoutState = false
        var updateError: Error?
        var updatedRevision = originalRevision
        do {
            _ = try gitRunner.run(
                [
                    "-C", rootDirectory.path,
                    "restore", "--source=HEAD", "--staged", "--worktree", "--", packageListPath
                ],
                description: "Prepare MacEntire update"
            )
            _ = try gitRunner.run(
                ["-C", rootDirectory.path, "fetch"],
                description: "Fetch MacEntire"
            )
            preservePostFetchCheckoutState = true
            let branchAfterFetch = try gitRunner.run(
                ["-C", rootDirectory.path, "branch", "--show-current"],
                description: "Revalidate MacEntire branch"
            )
            guard !branchAfterFetch.isEmpty else {
                throw PackageSyncError.detachedHead("MacEntire")
            }
            guard branchAfterFetch == originalBranch else {
                throw PackageSyncError.branchMismatch(
                    repository: "MacEntire",
                    expected: originalBranch,
                    actual: branchAfterFetch
                )
            }
            let revisionAfterFetch = try gitRunner.run(
                ["-C", rootDirectory.path, "rev-parse", "HEAD"],
                description: "Revalidate MacEntire revision"
            )
            guard revisionAfterFetch == originalRevision else {
                throw PackageSyncError.localChanges("MacEntire")
            }
            preservePostFetchCheckoutState = false
            _ = try gitRunner.run(
                [
                    "-C", rootDirectory.path,
                    "merge", "--ff-only", "--no-overwrite-ignore", "\(originalBranch)@{upstream}"
                ],
                description: "Update MacEntire"
            )
            updatedRevision = try gitRunner.run(
                ["-C", rootDirectory.path, "rev-parse", "HEAD"],
                description: "Read updated MacEntire revision"
            )
        } catch {
            updateError = error
        }

        var restorationError: Error?
        var packageListWasEditedDuringUpdate = preservePostFetchCheckoutState
        var packageListWasStagedDuringUpdate = preservePostFetchCheckoutState
        var packageListIndexWasTouchedDuringUpdate = preservePostFetchCheckoutState
        if !preservePostFetchCheckoutState {
            do {
                let packageListStatus = try gitRunner.run(
                    [
                        "--no-optional-locks", "-C", rootDirectory.path,
                        "status", "--porcelain", "--", packageListPath
                    ],
                    description: "Check for concurrent MacEntire package list edits"
                )
                packageListWasEditedDuringUpdate = !packageListStatus.isEmpty
                packageListWasStagedDuringUpdate = packageListStatus.first.map {
                    $0 != " "
                } ?? false
                let currentIndexEntry = try packageListIndexEntry(
                    from: gitRunner.run(
                        ["-C", rootDirectory.path, "ls-files", "--stage", "--", packageListPath],
                        description: "Check MacEntire package list index"
                    )
                )
                let updatedHeadIndexEntry = packageListTreeEntry(
                    from: try gitRunner.run(
                        ["-C", rootDirectory.path, "ls-tree", "HEAD", "--", packageListPath],
                        description: "Check updated MacEntire package list"
                    )
                )
                packageListIndexWasTouchedDuringUpdate = currentIndexEntry != updatedHeadIndexEntry
            } catch {
                restorationError = error
            }
        }

        do {
            try fileManager.createDirectory(
                at: workspace.packagesDirectory,
                withIntermediateDirectories: true
            )
            if let preservedPackageListLinkDestination, !packageListWasEditedDuringUpdate {
                if
                    fileManager.fileExists(atPath: workspace.packageListURL.path)
                        || isSymbolicLink(at: workspace.packageListURL, fileManager: fileManager)
                {
                    try fileManager.removeItem(at: workspace.packageListURL)
                }
                try fileManager.createSymbolicLink(
                    atPath: workspace.packageListURL.path,
                    withDestinationPath: preservedPackageListLinkDestination
                )
            } else if !packageListWasEditedDuringUpdate {
                try preservedPackageList.write(to: workspace.packageListURL, options: .atomic)
                if let preservedPackageListPermissions {
                    try fileManager.setAttributes(
                        [.posixPermissions: preservedPackageListPermissions],
                        ofItemAtPath: workspace.packageListURL.path
                    )
                }
            }
        } catch {
            restorationError = error
        }

        if
            packageListHadStagedChanges,
            !packageListWasStagedDuringUpdate,
            !packageListIndexWasTouchedDuringUpdate
        {
            do {
                if let preservedIndexEntry {
                    _ = try gitRunner.run(
                        [
                            "-C", rootDirectory.path,
                            "update-index", "--add", "--cacheinfo",
                            "\(preservedIndexEntry.mode),\(preservedIndexEntry.objectID),\(packageListPath)"
                        ],
                        description: "Restore MacEntire package list index"
                    )
                } else {
                    _ = try gitRunner.run(
                        ["-C", rootDirectory.path, "update-index", "--force-remove", "--", packageListPath],
                        description: "Restore MacEntire package list index"
                    )
                }
            } catch {
                restorationError = restorationError ?? error
            }
        }

        if preservePostFetchCheckoutState, let updateError {
            throw PackageSyncError.packageListRecoveryRequired(
                reason: updateError.localizedDescription,
                location: packageListRecovery.directoryURL.path
            )
        }

        if let restorationError {
            throw PackageSyncError.packageListRestorationFailed(
                "\(restorationError.localizedDescription) Original state was saved to "
                    + "\(packageListRecovery.directoryURL.path).",
                requiresReinstallation: updatedRevision != originalRevision
            )
        }

        removePackageListRecovery(
            packageListRecovery,
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )

        if let updateError {
            throw updateError
        }

        return updatedRevision != originalRevision
    }

    private func createPackageListRecovery(
        rootDirectory: URL,
        gitDirectory: URL,
        originalBranch: String,
        preservedPackageList: Data,
        symbolicLinkDestination: String?,
        indexWasCustomized: Bool,
        preservedIndexEntry: GitFileEntry?,
        packageListPath: String,
        fileManager: FileManager
    ) throws -> PackageListRecoverySnapshot {
        let identifier = UUID().uuidString.lowercased()
        let directoryURL = gitDirectory
            .appendingPathComponent("macentire-recovery", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var indexReference: String?
        do {
            try preservedPackageList.write(
                to: directoryURL.appendingPathComponent("packages.txt.worktree"),
                options: .atomic
            )
            if let symbolicLinkDestination {
                try Data(symbolicLinkDestination.utf8).write(
                    to: directoryURL.appendingPathComponent("packages.txt.symlink-destination"),
                    options: .atomic
                )
            }

            if indexWasCustomized {
                let indexMetadata: String
                if let preservedIndexEntry {
                    let reference = "refs/macentire-recovery/\(identifier)/package-list-index"
                    _ = try gitRunner.run(
                        ["-C", rootDirectory.path, "update-ref", reference, preservedIndexEntry.objectID],
                        description: "Retain staged MacEntire package list recovery"
                    )
                    indexReference = reference
                    indexMetadata = """
                    mode: \(preservedIndexEntry.mode)
                    object: \(preservedIndexEntry.objectID)
                    path: \(packageListPath)
                    reference: \(reference)
                    """
                } else {
                    indexMetadata = """
                    deleted: true
                    path: \(packageListPath)
                    """
                }
                try Data(indexMetadata.utf8).write(
                    to: directoryURL.appendingPathComponent("packages.txt.index"),
                    options: .atomic
                )
            }

            var instructions = """
            MacEntire package-list recovery
            Original branch: \(originalBranch)
            Original worktree content: packages.txt.worktree
            """
            if symbolicLinkDestination != nil {
                instructions += "\nOriginal symbolic-link destination: packages.txt.symlink-destination"
            }
            if let indexReference {
                instructions += "\nOriginal staged content: git show \(indexReference)"
            }
            instructions += "\n"
            try Data(instructions.utf8).write(
                to: directoryURL.appendingPathComponent("README.txt"),
                options: .atomic
            )
        } catch {
            if let indexReference {
                _ = try? gitRunner.run(
                    ["-C", rootDirectory.path, "update-ref", "-d", indexReference],
                    description: "Discard incomplete MacEntire package list recovery"
                )
            }
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }

        return PackageListRecoverySnapshot(
            directoryURL: directoryURL,
            indexReference: indexReference
        )
    }

    private func removePackageListRecovery(
        _ recovery: PackageListRecoverySnapshot,
        rootDirectory: URL,
        fileManager: FileManager
    ) {
        if let indexReference = recovery.indexReference {
            _ = try? gitRunner.run(
                ["-C", rootDirectory.path, "update-ref", "-d", indexReference],
                description: "Remove MacEntire package list recovery reference"
            )
        }
        try? fileManager.removeItem(at: recovery.directoryURL)
    }

    public func synchronize(_ package: PackageDefinition) throws {
        guard !isSymbolicLink(at: workspace.packagesDirectory) else {
            throw PackageSyncError.symbolicLinkPackagesDirectory
        }

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
                ["-C", package.directoryURL.path, "config", "--get", "remote.origin.url"],
                description: "Read \(package.repositoryName) origin"
            )
            let verifiedRemote = normalizedGitRemote(remote)
            guard verifiedRemote == normalizedGitRemote(package.repositoryURL.absoluteString) else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remote)
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
            let remoteAfterFetch = try gitRunner.run(
                ["-C", package.directoryURL.path, "config", "--get", "remote.origin.url"],
                description: "Revalidate \(package.repositoryName) origin"
            )
            guard normalizedGitRemote(remoteAfterFetch) == verifiedRemote else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remoteAfterFetch)
                )
            }
            let branchAfterFetch = try gitRunner.run(
                ["-C", package.directoryURL.path, "branch", "--show-current"],
                description: "Revalidate \(package.repositoryName) branch"
            )
            guard !branchAfterFetch.isEmpty else {
                throw PackageSyncError.detachedHead(package.repositoryName)
            }
            guard branchAfterFetch == branch else {
                throw PackageSyncError.branchMismatch(
                    repository: package.repositoryName,
                    expected: branch,
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
                ["-C", package.directoryURL.path, "config", "--get", "remote.origin.url"],
                description: "Read \(package.repositoryName) origin"
            )
            guard normalizedGitRemote(remote) == normalizedGitRemote(package.repositoryURL.absoluteString) else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remote)
                )
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
        }

        var launcherIsDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: package.launcherURL.path, isDirectory: &launcherIsDirectory),
            !launcherIsDirectory.boolValue
        else {
            throw PackageSyncError.missingLauncher(package.repositoryName)
        }
        guard FileManager.default.isExecutableFile(atPath: package.launcherURL.path) else {
            throw PackageSyncError.nonExecutableLauncher(package.repositoryName)
        }
    }
}

private struct GitFileEntry: Equatable {
    let mode: String
    let objectID: String
}

private struct PackageListRecoverySnapshot {
    let directoryURL: URL
    let indexReference: String?
}

private func packageListIndexEntry(from output: String) throws -> GitFileEntry? {
    let lines = output.split(whereSeparator: \.isNewline)
    guard !lines.isEmpty else {
        return nil
    }
    guard lines.count == 1 else {
        throw PackageSyncError.packageListRestorationFailed(
            "The package list has unresolved index entries.",
            requiresReinstallation: false
        )
    }

    let metadata = lines[0]
        .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(whereSeparator: \.isWhitespace)
    guard metadata.count == 3, metadata[2] == "0" else {
        throw PackageSyncError.packageListRestorationFailed(
            "The package list index entry could not be read.",
            requiresReinstallation: false
        )
    }
    return GitFileEntry(mode: String(metadata[0]), objectID: String(metadata[1]))
}

private func packageListTreeEntry(from output: String) -> GitFileEntry? {
    guard let line = output.split(whereSeparator: \.isNewline).first else {
        return nil
    }
    let metadata = line
        .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .split(whereSeparator: \.isWhitespace)
    guard metadata.count == 3 else {
        return nil
    }
    return GitFileEntry(mode: String(metadata[0]), objectID: String(metadata[2]))
}

func normalizedGitRemote(_ value: String) -> String {
    var normalized = redactedGitRemote(value)
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    if normalized.lowercased().hasSuffix(".git") {
        normalized.removeLast(4)
    }
    return normalized.lowercased()
}

func redactedGitRemote(_ value: String) -> String {
    let remote = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let schemeDelimiter = remote.range(of: "://") else {
        return remote
    }

    let authorityStart = schemeDelimiter.upperBound
    let authoritySuffix = remote[authorityStart...]
    let authorityEnd = authoritySuffix.firstIndex { character in
        character == "/" || character == "?" || character == "#"
    } ?? remote.endIndex
    let authority = remote[authorityStart..<authorityEnd]
    guard let userInformationEnd = authority.lastIndex(of: "@") else {
        return remote
    }

    return String(remote[..<authorityStart])
        + String(remote[remote.index(after: userInformationEnd)...])
}
