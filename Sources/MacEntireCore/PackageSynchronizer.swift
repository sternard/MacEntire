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
    case branchRevisionChanged(String)
    case checkoutChanged(String)
    case detachedHead(String)
    case gitMetadataOutsideCheckout(String)
    case localChanges(String)
    case missingLauncher(String)
    case nonExecutableLauncher(String)
    case macEntireIsNotRepository
    case macEntireCheckoutChanged
    case macEntireUpdateFailedAfterMerge(String)
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
        case .branchRevisionChanged(let name):
            return "\(name) branch changed during update; update skipped."
        case .checkoutChanged(let name):
            return "\(name) checkout changed during update; update skipped."
        case .detachedHead(let name):
            return "\(name) has a detached HEAD; update skipped."
        case .gitMetadataOutsideCheckout(let name):
            return "\(name) Git metadata is outside its checkout; update skipped."
        case .localChanges(let name):
            return "\(name) has local changes; update skipped."
        case .missingLauncher(let name):
            return "\(name) does not contain scripts/run-app.sh."
        case .nonExecutableLauncher(let name):
            return "\(name) scripts/run-app.sh is not executable."
        case .macEntireIsNotRepository:
            return "The configured MacEntire root is not the root of a Git repository."
        case .macEntireCheckoutChanged:
            return "The configured MacEntire root changed during the update; update skipped."
        case .macEntireUpdateFailedAfterMerge(let reason):
            return reason
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
        case .macEntireUpdateFailedAfterMerge:
            return true
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
        switch macEntireSyncError {
        case .packageListRecoveryRequired, .packageListRestorationFailed:
            definitions = []
            packageListErrorMessage = nil
        default:
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
        let rootDirectory = workspace.rootDirectory
        let rootDirectoryHandle = try openStableDirectory(rootDirectory)
        let checkoutURL = rootDirectoryHandle.url
        let packagesDirectory = try openManagedPackagesDirectory(rootDirectory: checkoutURL)
        let packageListURL = packagesDirectory.url.appendingPathComponent(
            PackageListParser.packageListFilename
        )
        let resolvedTopLevel = try gitRunner.run(
            ["-C", checkoutURL.path, "rev-parse", "--show-toplevel"],
            description: "Validate MacEntire checkout"
        )
        let resolvedTopLevelURL = URL(fileURLWithPath: resolvedTopLevel, isDirectory: true)
        guard rootDirectoryHandle.matches(resolvedTopLevelURL) else {
            throw PackageSyncError.macEntireIsNotRepository
        }
        let originalBranch = try gitRunner.run(
            ["-C", checkoutURL.path, "branch", "--show-current"],
            description: "Read MacEntire branch"
        )
        guard !originalBranch.isEmpty else {
            throw PackageSyncError.detachedHead("MacEntire")
        }
        let originalRevision = try gitRunner.run(
            ["-C", checkoutURL.path, "rev-parse", "HEAD"],
            description: "Read current MacEntire revision"
        )
        let packageListIndexPath = try gitRunner.run(
            ["-C", checkoutURL.path, "rev-parse", "--git-path", "index"],
            description: "Locate MacEntire index"
        )
        let packageListIndexURL = URL(
            fileURLWithPath: packageListIndexPath,
            relativeTo: checkoutURL
        ).standardizedFileURL

        let fileManager = FileManager.default
        let preservedPackageListLinkDestination = try? fileManager.destinationOfSymbolicLink(
            atPath: packageListURL.path
        )
        let preservedPackageListPermissions: NSNumber?
        if preservedPackageListLinkDestination == nil {
            let attributes = try fileManager.attributesOfItem(atPath: packageListURL.path)
            preservedPackageListPermissions = attributes[.posixPermissions] as? NSNumber
        } else {
            preservedPackageListPermissions = nil
        }
        let preservedPackageList: Data
        do {
            preservedPackageList = try Data(contentsOf: packageListURL)
        } catch {
            throw PackageListError.unreadableFile(workspace.packageListURL.path)
        }

        let packageListPath = "Packages/\(PackageListParser.packageListFilename)"
        let preservedIndexEntry = try packageListIndexEntry(
            from: gitRunner.run(
                ["-C", checkoutURL.path, "ls-files", "--stage", "--", packageListPath],
                description: "Preserve MacEntire package list index"
            )
        )
        let headIndexEntry = packageListTreeEntry(
            from: try gitRunner.run(
                ["-C", checkoutURL.path, "ls-tree", "HEAD", "--", packageListPath],
                description: "Read committed MacEntire package list"
            )
        )
        let packageListHadStagedChanges = preservedIndexEntry != headIndexEntry
        let packageListRecovery: PackageListRecoverySnapshot
        do {
            packageListRecovery = try createPackageListRecovery(
                rootDirectory: checkoutURL,
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
        var updateRequiresReinstallation = false
        do {
            _ = try gitRunner.run(
                [
                    "-C", checkoutURL.path,
                    "restore", "--source=HEAD", "--staged", "--worktree", "--", packageListPath
                ],
                description: "Prepare MacEntire update"
            )
            preservePostFetchCheckoutState = true
            do {
                _ = try gitRunner.run(
                    ["-C", checkoutURL.path, "fetch"],
                    description: "Fetch MacEntire"
                )
            } catch {
                let fetchError = error
                do {
                    let branchAfterFailedFetch = try gitRunner.run(
                        ["-C", checkoutURL.path, "branch", "--show-current"],
                        description: "Revalidate MacEntire branch after fetch failure"
                    )
                    let revisionAfterFailedFetch = try gitRunner.run(
                        ["-C", checkoutURL.path, "rev-parse", "HEAD"],
                        description: "Revalidate MacEntire revision after fetch failure"
                    )
                    preservePostFetchCheckoutState = branchAfterFailedFetch != originalBranch
                        || revisionAfterFailedFetch != originalRevision
                        || !rootDirectoryHandle.matches(rootDirectory)
                } catch {
                    preservePostFetchCheckoutState = true
                }
                throw fetchError
            }
            let branchAfterFetch = try gitRunner.run(
                ["-C", checkoutURL.path, "branch", "--show-current"],
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
                ["-C", checkoutURL.path, "rev-parse", "HEAD"],
                description: "Revalidate MacEntire revision"
            )
            guard revisionAfterFetch == originalRevision else {
                throw PackageSyncError.localChanges("MacEntire")
            }
            guard rootDirectoryHandle.matches(rootDirectory) else {
                throw PackageSyncError.macEntireCheckoutChanged
            }
            preservePostFetchCheckoutState = false
            _ = try gitRunner.run(
                [
                    "-C", checkoutURL.path,
                    "merge", "--ff-only", "--no-overwrite-ignore", "\(originalBranch)@{upstream}"
                ],
                description: "Update MacEntire"
            )
            updateRequiresReinstallation = true
            updatedRevision = try gitRunner.run(
                ["-C", checkoutURL.path, "rev-parse", "HEAD"],
                description: "Read updated MacEntire revision"
            )
            updateRequiresReinstallation = updatedRevision != originalRevision
        } catch {
            updateError = error
        }

        var restorationError: Error?
        var packageListWasEditedDuringUpdate = preservePostFetchCheckoutState
        var packageListWasStagedDuringUpdate = preservePostFetchCheckoutState
        var packageListIndexWasTouchedDuringUpdate = preservePostFetchCheckoutState
        var packagesDirectoryWasReplaced = false
        var packageListLeafAfterEditCheck: PackageListLeafSnapshot?
        if !preservePostFetchCheckoutState {
            if !managedPackagesDirectoryIsCurrent(
                packagesDirectory,
                at: workspace.packagesDirectory
            ) {
                packagesDirectoryWasReplaced = true
                restorationError = PackageSyncError.symbolicLinkPackagesDirectory
            } else {
                do {
                    let packageListStatus = try gitRunner.run(
                        [
                            "--no-optional-locks", "-C", checkoutURL.path,
                            "status", "--porcelain", "--", packageListPath
                        ],
                        description: "Check for concurrent MacEntire package list edits"
                    )
                    packageListWasEditedDuringUpdate = !packageListStatus.isEmpty
                    if !packageListWasEditedDuringUpdate {
                        packageListLeafAfterEditCheck = try packageListLeafSnapshot(
                            at: packageListURL,
                            fileManager: fileManager
                        )
                    }
                    packageListWasStagedDuringUpdate = packageListStatus.first.map {
                        $0 != " "
                    } ?? false
                    let currentIndexEntry = try packageListIndexEntry(
                        from: gitRunner.run(
                            ["-C", checkoutURL.path, "ls-files", "--stage", "--", packageListPath],
                            description: "Check MacEntire package list index"
                        )
                    )
                    let updatedHeadIndexEntry = packageListTreeEntry(
                        from: try gitRunner.run(
                            ["-C", checkoutURL.path, "ls-tree", "HEAD", "--", packageListPath],
                            description: "Check updated MacEntire package list"
                        )
                    )
                    packageListIndexWasTouchedDuringUpdate = currentIndexEntry != updatedHeadIndexEntry
                } catch {
                    restorationError = error
                    if !packageListWasEditedDuringUpdate {
                        packageListLeafAfterEditCheck = try? packageListLeafSnapshot(
                            at: packageListURL,
                            fileManager: fileManager
                        )
                    }
                }
            }
        }

        if !packagesDirectoryWasReplaced {
            do {
                guard managedPackagesDirectoryIsCurrent(
                    packagesDirectory,
                    at: workspace.packagesDirectory
                ) else {
                    throw PackageSyncError.symbolicLinkPackagesDirectory
                }
                if !packageListWasEditedDuringUpdate,
                   let packageListLeafAfterEditCheck {
                    let restored = try restorePackageListIfUnchanged(
                        at: packageListURL,
                        expectedLeaf: packageListLeafAfterEditCheck,
                        preservedContents: preservedPackageList,
                        symbolicLinkDestination: preservedPackageListLinkDestination,
                        permissions: preservedPackageListPermissions,
                        fileManager: fileManager
                    )
                    if !restored {
                        packageListWasEditedDuringUpdate = true
                    }
                }
                guard managedPackagesDirectoryIsCurrent(
                    packagesDirectory,
                    at: workspace.packagesDirectory
                ) else {
                    throw PackageSyncError.symbolicLinkPackagesDirectory
                }
            } catch {
                if error as? PackageSyncError == .symbolicLinkPackagesDirectory {
                    packagesDirectoryWasReplaced = true
                }
                restorationError = restorationError ?? error
            }
        }

        if !managedPackagesDirectoryIsCurrent(
            packagesDirectory,
            at: workspace.packagesDirectory
        ) {
            packagesDirectoryWasReplaced = true
            restorationError = restorationError ?? PackageSyncError.symbolicLinkPackagesDirectory
        }

        if
            !packagesDirectoryWasReplaced,
            packageListHadStagedChanges,
            !packageListWasStagedDuringUpdate,
            !packageListIndexWasTouchedDuringUpdate
        {
            do {
                if let preservedIndexEntry {
                    _ = try gitRunner.run(
                        [
                            "-C", checkoutURL.path,
                            "update-index", "--add", "--cacheinfo",
                            "\(preservedIndexEntry.mode),\(preservedIndexEntry.objectID),\(packageListPath)"
                        ],
                        description: "Restore MacEntire package list index"
                    )
                } else {
                    _ = try gitRunner.run(
                        ["-C", checkoutURL.path, "update-index", "--force-remove", "--", packageListPath],
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
                requiresReinstallation: updateRequiresReinstallation
            )
        }

        removePackageListRecovery(
            packageListRecovery,
            rootDirectory: checkoutURL,
            fileManager: fileManager
        )

        if let updateError {
            if updateRequiresReinstallation {
                throw PackageSyncError.macEntireUpdateFailedAfterMerge(
                    updateError.localizedDescription
                )
            }
            throw updateError
        }

        return updateRequiresReinstallation
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
        let packagesDirectory = try openManagedPackagesDirectory(
            rootDirectory: workspace.rootDirectory
        )
        let checkoutDirectory: StableDirectoryHandle

        if let existingCheckout = try openManagedCheckout(
            named: package.repositoryName,
            in: packagesDirectory
        ) {
            checkoutDirectory = existingCheckout
            let checkoutURL = checkoutDirectory.url
            guard
                FileManager.default.fileExists(
                    atPath: checkoutURL.appendingPathComponent(".git").path
                )
            else {
                throw PackageSyncError.destinationIsNotRepository(package.repositoryName)
            }

            let resolvedTopLevel = try gitRunner.run(
                ["-C", checkoutURL.path, "rev-parse", "--show-toplevel"],
                description: "Validate \(package.repositoryName) checkout"
            )
            let resolvedTopLevelURL = URL(fileURLWithPath: resolvedTopLevel, isDirectory: true)
            guard checkoutDirectory.matches(resolvedTopLevelURL) else {
                throw PackageSyncError.destinationIsNotRepository(package.repositoryName)
            }

            let resolvedGitDirectory = try gitRunner.run(
                ["-C", checkoutURL.path, "rev-parse", "--absolute-git-dir"],
                description: "Validate \(package.repositoryName) Git metadata"
            )
            guard gitMetadataDirectoryMatchesCheckout(
                URL(fileURLWithPath: resolvedGitDirectory, isDirectory: true),
                checkoutDirectory: checkoutDirectory
            ) else {
                throw PackageSyncError.gitMetadataOutsideCheckout(package.repositoryName)
            }

            let remoteOutput = try gitRunner.run(
                ["-C", checkoutURL.path, "config", "--get-all", "remote.origin.url"],
                description: "Read \(package.repositoryName) origin"
            )
            let remote = try singleStoredGitRemote(
                remoteOutput,
                expected: package.repositoryURL.absoluteString
            )
            let verifiedRemote = normalizedGitRemote(remote)
            guard verifiedRemote == normalizedGitRemote(package.repositoryURL.absoluteString) else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remote)
                )
            }

            let changes = try gitRunner.run(
                ["-C", checkoutURL.path, "status", "--porcelain"],
                description: "Check \(package.repositoryName)"
            )
            guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PackageSyncError.localChanges(package.repositoryName)
            }

            let currentBranch = try gitRunner.run(
                ["-C", checkoutURL.path, "branch", "--show-current"],
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

            let revision = try gitRunner.run(
                ["-C", checkoutURL.path, "rev-parse", "HEAD"],
                description: "Read \(package.repositoryName) revision"
            )
            let branch = package.branch ?? currentBranch
            _ = try gitRunner.run(
                ["-C", checkoutURL.path, "fetch", "origin", "refs/heads/\(branch)"],
                description: "Fetch \(package.repositoryName)"
            )
            let remoteOutputAfterFetch = try gitRunner.run(
                ["-C", checkoutURL.path, "config", "--get-all", "remote.origin.url"],
                description: "Revalidate \(package.repositoryName) origin"
            )
            let remoteAfterFetch = try singleStoredGitRemote(
                remoteOutputAfterFetch,
                expected: package.repositoryURL.absoluteString
            )
            guard normalizedGitRemote(remoteAfterFetch) == verifiedRemote else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remoteAfterFetch)
                )
            }
            let branchAfterFetch = try gitRunner.run(
                ["-C", checkoutURL.path, "branch", "--show-current"],
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
            let revisionAfterFetch = try gitRunner.run(
                ["-C", checkoutURL.path, "rev-parse", "HEAD"],
                description: "Revalidate \(package.repositoryName) revision"
            )
            guard revisionAfterFetch == revision else {
                throw PackageSyncError.branchRevisionChanged(package.repositoryName)
            }
            let changesAfterFetch = try gitRunner.run(
                ["-C", checkoutURL.path, "status", "--porcelain"],
                description: "Recheck \(package.repositoryName)"
            )
            guard changesAfterFetch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PackageSyncError.localChanges(package.repositoryName)
            }
            let visibleCheckout = packagesDirectory.url.appendingPathComponent(
                package.repositoryName,
                isDirectory: true
            )
            guard
                managedPackagesDirectoryIsCurrent(
                    packagesDirectory,
                    at: workspace.packagesDirectory
                ),
                !isSymbolicLink(at: visibleCheckout),
                checkoutDirectory.matches(visibleCheckout)
            else {
                throw PackageSyncError.checkoutChanged(package.repositoryName)
            }
            _ = try gitRunner.run(
                [
                    "-C", checkoutURL.path,
                    "merge", "--ff-only", "--no-overwrite-ignore", "FETCH_HEAD"
                ],
                description: "Update \(package.repositoryName)"
            )
        } else {
            let configuredRemote = package.repositoryURL.absoluteString
            let effectiveRemoteOutput = try gitRunner.run(
                ["ls-remote", "--get-url", configuredRemote],
                description: "Resolve \(package.repositoryName) clone URL"
            )
            let effectiveRemote = try singleStoredGitRemote(
                effectiveRemoteOutput,
                expected: configuredRemote
            )
            guard gitHubRepositoryIdentity(effectiveRemote)
                == gitHubRepositoryIdentity(configuredRemote) else {
                throw PackageSyncError.remoteMismatch(
                    expected: configuredRemote,
                    actual: redactedGitRemote(effectiveRemote)
                )
            }

            checkoutDirectory = try reserveManagedCheckout(
                named: package.repositoryName,
                in: packagesDirectory
            )
            var cloneArguments = ["clone", "--origin", "origin"]
            if let branch = package.branch {
                cloneArguments.append(contentsOf: ["--branch", branch, "--single-branch"])
            }
            let cloneDestination = checkoutDirectory.url
            cloneArguments.append(contentsOf: [effectiveRemote, cloneDestination.path])
            do {
                _ = try gitRunner.run(
                    cloneArguments,
                    description: "Clone \(package.repositoryName)"
                )
            } catch {
                removeReservedCheckoutAfterCloneFailure(
                    checkoutDirectory,
                    named: package.repositoryName,
                    from: packagesDirectory
                )
                throw error
            }

            let checkoutURL = checkoutDirectory.url

            let remoteOutput = try gitRunner.run(
                ["-C", checkoutURL.path, "config", "--get-all", "remote.origin.url"],
                description: "Read \(package.repositoryName) origin"
            )
            let remote = try singleStoredGitRemote(
                remoteOutput,
                expected: package.repositoryURL.absoluteString
            )
            guard normalizedGitRemote(remote) == normalizedGitRemote(package.repositoryURL.absoluteString) else {
                throw PackageSyncError.remoteMismatch(
                    expected: package.repositoryURL.absoluteString,
                    actual: redactedGitRemote(remote)
                )
            }

            let currentBranch = try gitRunner.run(
                ["-C", checkoutURL.path, "branch", "--show-current"],
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

        let launcherURL = checkoutDirectory.url.appendingPathComponent("scripts/run-app.sh")
        var launcherIsDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: launcherURL.path, isDirectory: &launcherIsDirectory),
            !launcherIsDirectory.boolValue
        else {
            throw PackageSyncError.missingLauncher(package.repositoryName)
        }
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            throw PackageSyncError.nonExecutableLauncher(package.repositoryName)
        }
    }
}

final class StableDirectoryHandle: @unchecked Sendable {
    let descriptor: Int32
    let device: dev_t
    let inode: ino_t

    init(descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let error = posixError(errno)
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    deinit {
        close(descriptor)
    }

    var url: URL {
        URL(fileURLWithPath: "/.vol/\(device)/\(inode)", isDirectory: true)
    }

    func matches(_ candidateURL: URL) -> Bool {
        var metadata = stat()
        guard fstatat(AT_FDCWD, candidateURL.path, &metadata, 0) == 0 else {
            return false
        }
        return metadata.st_dev == device && metadata.st_ino == inode
    }
}

func gitMetadataDirectoryMatchesCheckout(
    _ resolvedGitDirectory: URL,
    checkoutDirectory: StableDirectoryHandle
) -> Bool {
    let descriptor = openat(
        checkoutDirectory.descriptor,
        ".git",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0,
          let gitDirectory = try? StableDirectoryHandle(descriptor: descriptor) else {
        return false
    }
    return gitDirectory.matches(resolvedGitDirectory)
}

func openStableDirectory(_ directoryURL: URL) throws -> StableDirectoryHandle {
    let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else {
        throw posixError(errno)
    }
    return try StableDirectoryHandle(descriptor: descriptor)
}

func openManagedPackagesDirectory(rootDirectory: URL) throws -> StableDirectoryHandle {
    let rootDescriptor = open(rootDirectory.path, O_RDONLY | O_DIRECTORY)
    guard rootDescriptor >= 0 else {
        throw posixError(errno)
    }
    defer { close(rootDescriptor) }

    if mkdirat(rootDescriptor, "Packages", 0o755) != 0, errno != EEXIST {
        throw posixError(errno)
    }

    let descriptor = openat(
        rootDescriptor,
        "Packages",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        if errno == ELOOP || isSymbolicLink(at: rootDirectory.appendingPathComponent("Packages")) {
            throw PackageSyncError.symbolicLinkPackagesDirectory
        }
        throw posixError(errno)
    }
    return try StableDirectoryHandle(descriptor: descriptor)
}

func managedPackagesDirectoryIsCurrent(
    _ packagesDirectory: StableDirectoryHandle,
    at visibleURL: URL
) -> Bool {
    !isSymbolicLink(at: visibleURL) && packagesDirectory.matches(visibleURL)
}

func openManagedCheckout(
    named repositoryName: String,
    in packagesDirectory: StableDirectoryHandle
) throws -> StableDirectoryHandle? {
    let descriptor = openat(
        packagesDirectory.descriptor,
        repositoryName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        if errno == ENOENT {
            return nil
        }
        if errno == ELOOP || isSymbolicLink(
            at: packagesDirectory.url.appendingPathComponent(repositoryName)
        ) {
            throw PackageSyncError.symbolicLinkCheckout(repositoryName)
        }
        if errno == ENOTDIR {
            throw PackageSyncError.destinationIsNotRepository(repositoryName)
        }
        throw posixError(errno)
    }
    return try StableDirectoryHandle(descriptor: descriptor)
}

func reserveManagedCheckout(
    named repositoryName: String,
    in packagesDirectory: StableDirectoryHandle
) throws -> StableDirectoryHandle {
    guard mkdirat(packagesDirectory.descriptor, repositoryName, 0o755) == 0 else {
        if errno == EEXIST {
            _ = try openManagedCheckout(
                named: repositoryName,
                in: packagesDirectory
            )
            throw PackageSyncError.destinationIsNotRepository(repositoryName)
        }
        throw posixError(errno)
    }

    guard let checkoutDirectory = try openManagedCheckout(
        named: repositoryName,
        in: packagesDirectory
    ) else {
        throw PackageSyncError.destinationIsNotRepository(repositoryName)
    }
    return checkoutDirectory
}

private func removeReservedCheckoutAfterCloneFailure(
    _ checkoutDirectory: StableDirectoryHandle,
    named repositoryName: String,
    from packagesDirectory: StableDirectoryHandle,
    fileManager: FileManager = .default
) {
    let visibleCheckout = packagesDirectory.url.appendingPathComponent(
        repositoryName,
        isDirectory: true
    )
    guard checkoutDirectory.matches(visibleCheckout) else {
        return
    }

    let entries = (try? fileManager.contentsOfDirectory(
        at: checkoutDirectory.url,
        includingPropertiesForKeys: nil
    )) ?? []
    for entry in entries {
        guard checkoutDirectory.matches(visibleCheckout) else {
            return
        }
        try? fileManager.removeItem(at: entry)
    }

    guard checkoutDirectory.matches(visibleCheckout) else {
        return
    }
    _ = unlinkat(packagesDirectory.descriptor, repositoryName, AT_REMOVEDIR)
}

private struct GitFileEntry: Equatable {
    let mode: String
    let objectID: String
}

private enum PackageListLeafSnapshot: Equatable {
    case regular(contents: Data, permissions: NSNumber?)
    case symbolicLink(destination: String)
}

private func packageListLeafSnapshot(
    at url: URL,
    fileManager: FileManager
) throws -> PackageListLeafSnapshot {
    if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
        return .symbolicLink(destination: destination)
    }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return .regular(
        contents: try Data(contentsOf: url),
        permissions: attributes[.posixPermissions] as? NSNumber
    )
}

private func restorePackageListIfUnchanged(
    at url: URL,
    expectedLeaf: PackageListLeafSnapshot,
    preservedContents: Data,
    symbolicLinkDestination: String?,
    permissions: NSNumber?,
    fileManager: FileManager
) throws -> Bool {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var restoreError: Error?
    var restored = false

    coordinator.coordinate(
        writingItemAt: url,
        options: .forReplacing,
        error: &coordinationError
    ) { coordinatedURL in
        do {
            guard try packageListLeafSnapshot(
                at: coordinatedURL,
                fileManager: fileManager
            ) == expectedLeaf else {
                return
            }
            if let symbolicLinkDestination {
                try fileManager.removeItem(at: coordinatedURL)
                try fileManager.createSymbolicLink(
                    atPath: coordinatedURL.path,
                    withDestinationPath: symbolicLinkDestination
                )
            } else {
                try preservedContents.write(to: coordinatedURL, options: .atomic)
                if let permissions {
                    try fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: coordinatedURL.path
                    )
                }
            }
            restored = true
        } catch {
            restoreError = error
        }
    }

    if let restoreError {
        throw restoreError
    }
    if let coordinationError {
        throw coordinationError
    }
    return restored
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

func singleStoredGitRemote(_ output: String, expected: String) throws -> String {
    let remotes = output.split(whereSeparator: \.isNewline).map(String.init)
    guard remotes.count == 1, let remote = remotes.first else {
        throw PackageSyncError.remoteMismatch(
            expected: expected,
            actual: remotes.map(redactedGitRemote).joined(separator: ", ")
        )
    }
    return remote
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

func gitHubRepositoryIdentity(_ value: String) -> String? {
    let remote = redactedGitRemote(value)
    let repositoryPath: String

    if remote.contains("://") {
        guard
            let url = URL(string: remote),
            let scheme = url.scheme?.lowercased(),
            ["git", "http", "https", "ssh"].contains(scheme),
            url.host?.lowercased() == "github.com",
            url.query == nil,
            url.fragment == nil
        else {
            return nil
        }
        repositoryPath = url.path
    } else {
        let hostAndPath = remote.split(separator: "@", maxSplits: 1).last.map(String.init) ?? remote
        guard let separator = hostAndPath.firstIndex(of: ":") else {
            return nil
        }
        guard hostAndPath[..<separator].lowercased() == "github.com" else {
            return nil
        }
        repositoryPath = String(hostAndPath[hostAndPath.index(after: separator)...])
    }

    var components = repositoryPath.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count == 2 else {
        return nil
    }
    if components[1].lowercased().hasSuffix(".git") {
        components[1] = components[1].dropLast(4)
    }
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        return nil
    }
    return components.map { $0.lowercased() }.joined(separator: "/")
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
