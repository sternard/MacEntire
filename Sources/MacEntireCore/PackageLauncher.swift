import Darwin
import Foundation

public enum PackageLaunchError: LocalizedError, Equatable, Sendable {
    static let maximumDisplayedOutputCharacters = 200

    case unsuccessfulExit(package: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .unsuccessfulExit(let package, let status, let output):
            let summary = Self.displayedOutputSummary(output)
            if summary.isEmpty {
                return "\(package) launcher exited with status \(status)."
            }
            return "\(package) launcher exited with status \(status): \(summary)"
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
}

public func packageLaunchCompletionMessage(
    for result: Result<Void, PackageLaunchError>
) -> String? {
    switch result {
    case .success:
        return nil
    case .failure(let error):
        return error.localizedDescription
    }
}

public struct PackageLaunchStatusState: Equatable, Sendable {
    private var launchOrder: [UUID] = []
    private var messages: [UUID: String] = [:]
    private var packageIdentifiers: [UUID: String] = [:]

    public var message: String? {
        launchOrder.reversed().compactMap { messages[$0] }.first
    }

    public func message(fallingBackTo fallbackMessage: String?) -> String? {
        message ?? fallbackMessage
    }

    public init() {}

    @discardableResult
    public mutating func beginLaunch(
        packageIdentifier: String,
        packageName: String,
        identifier: UUID = UUID()
    ) -> UUID {
        let supersededLaunches = launchOrder.filter {
            packageIdentifiers[$0] == packageIdentifier
        }
        for supersededIdentifier in supersededLaunches {
            removeLaunch(supersededIdentifier)
        }
        launchOrder.removeAll { $0 == identifier }
        launchOrder.append(identifier)
        messages[identifier] = "Launching \(packageName)…"
        packageIdentifiers[identifier] = packageIdentifier
        return identifier
    }

    public mutating func completeLaunch(
        identifier: UUID,
        result: Result<Void, PackageLaunchError>
    ) {
        guard packageIdentifiers[identifier] != nil else {
            return
        }
        if let message = packageLaunchCompletionMessage(for: result) {
            messages[identifier] = message
        } else {
            removeLaunch(identifier)
        }
    }

    public mutating func failToStart(identifier: UUID, message: String) {
        guard packageIdentifiers[identifier] != nil else {
            return
        }
        messages[identifier] = message
    }

    private mutating func removeLaunch(_ identifier: UUID) {
        messages[identifier] = nil
        packageIdentifiers[identifier] = nil
        launchOrder.removeAll { $0 == identifier }
    }
}

public final class PackageLauncher: @unchecked Sendable {
    static let maximumCapturedOutputBytes = 64 * 1024

    private let lock = NSLock()
    private var runningProcesses: [UUID: Process] = [:]
    private var outputCaptures: [UUID: LauncherOutputCapture] = [:]

    var activeOutputCaptureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outputCaptures.count
    }

    public init() {}

    public func launch(
        _ package: PackageDefinition,
        completion: @escaping @Sendable (Result<Void, PackageLaunchError>) -> Void
    ) throws {
        let identifier = UUID()
        let outputCapture = LauncherOutputCapture(maximumBytes: Self.maximumCapturedOutputBytes) { [weak self] in
            self?.removeOutputCapture(identifier)
        }
        let process = Process()
        process.executableURL = package.launcherURL
        process.currentDirectoryURL = package.directoryURL
        process.standardOutput = outputCapture.writer
        process.standardError = outputCapture.writer
        process.terminationHandler = { [weak self] process in
            self?.removeProcess(identifier)
            let capturedOutput = outputCapture.finishCapturing()

            guard process.terminationStatus != 0 else {
                completion(.success(()))
                return
            }

            completion(.failure(.unsuccessfulExit(
                package: package.displayName,
                status: process.terminationStatus,
                output: capturedOutput
            )))
        }

        storeProcess(process, outputCapture: outputCapture, identifier: identifier)
        do {
            try process.run()
            outputCapture.closeParentWriter()
        } catch {
            removeProcessAndOutputCapture(identifier)
            throw error
        }
    }

    private func storeProcess(
        _ process: Process,
        outputCapture: LauncherOutputCapture,
        identifier: UUID
    ) {
        lock.lock()
        runningProcesses[identifier] = process
        outputCaptures[identifier] = outputCapture
        lock.unlock()
    }

    private func removeProcess(_ identifier: UUID) {
        lock.lock()
        runningProcesses[identifier] = nil
        lock.unlock()
    }

    private func removeOutputCapture(_ identifier: UUID) {
        lock.lock()
        outputCaptures[identifier] = nil
        lock.unlock()
    }

    private func removeProcessAndOutputCapture(_ identifier: UUID) {
        lock.lock()
        runningProcesses[identifier] = nil
        let outputCapture = outputCaptures.removeValue(forKey: identifier)
        lock.unlock()
        outputCapture?.cancel()
    }
}

private final class LauncherOutputCapture: @unchecked Sendable {
    private static let maximumBytesPerDrain = 64 * 1024

    let writer: FileHandle

    private let reader: FileHandle
    private let output: BoundedProcessOutput
    private let lock = NSLock()
    private let onEnd: @Sendable () -> Void
    private var writerIsClosed = false
    private var readerIsClosed = false
    private var captureDidFinish = false
    private var didNotifyEnd = false

    init(maximumBytes: Int, onEnd: @escaping @Sendable () -> Void) {
        let pipe = Pipe()
        reader = pipe.fileHandleForReading
        writer = pipe.fileHandleForWriting
        output = BoundedProcessOutput(maximumBytes: maximumBytes)
        self.onEnd = onEnd
        let descriptor = reader.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        reader.readabilityHandler = { [self] _ in
            drainAvailableOutput()
        }
    }

    func finishCapturing() -> String {
        lock.lock()
        let shouldCloseReader = drainAvailableOutputLocked()
        captureDidFinish = true
        let shouldNotifyEnd = markEndNotificationLocked()
        let capturedOutput = output.string
        lock.unlock()

        closeReaderIfNeeded(shouldCloseReader)
        if shouldNotifyEnd {
            onEnd()
        }
        return capturedOutput
    }

    func closeParentWriter() {
        lock.lock()
        guard !writerIsClosed else {
            lock.unlock()
            return
        }
        writerIsClosed = true
        lock.unlock()
        try? writer.close()
    }

    func cancel() {
        lock.lock()
        captureDidFinish = true
        let shouldCloseReader = !readerIsClosed
        readerIsClosed = true
        lock.unlock()

        closeParentWriter()
        closeReaderIfNeeded(shouldCloseReader)
    }

    private func drainAvailableOutput() {
        lock.lock()
        let shouldCloseReader = drainAvailableOutputLocked()
        let shouldNotifyEnd = readerIsClosed && markEndNotificationLocked()
        lock.unlock()

        closeReaderIfNeeded(shouldCloseReader)
        if shouldNotifyEnd {
            onEnd()
        }
    }

    private func drainAvailableOutputLocked() -> Bool {
        guard !readerIsClosed else {
            return false
        }

        let descriptor = reader.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        var remainingBytes = Self.maximumBytesPerDrain
        while remainingBytes > 0 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remainingBytes))
            }
            if count > 0 {
                if !captureDidFinish {
                    output.append(Data(buffer.prefix(count)))
                }
                remainingBytes -= count
                continue
            }
            if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                readerIsClosed = true
                return true
            }
            return false
        }
        return false
    }

    private func markEndNotificationLocked() -> Bool {
        guard !didNotifyEnd else {
            return false
        }
        didNotifyEnd = true
        return true
    }

    private func closeReaderIfNeeded(_ shouldClose: Bool) {
        guard shouldClose else {
            return
        }
        reader.readabilityHandler = nil
        try? reader.close()
    }
}
