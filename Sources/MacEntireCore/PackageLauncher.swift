import Darwin
import Foundation

public enum PackageLaunchError: LocalizedError, Equatable, Sendable {
    case unsuccessfulExit(package: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .unsuccessfulExit(let package, let status, let output):
            if output.isEmpty {
                return "\(package) launcher exited with status \(status)."
            }
            return "\(package) launcher exited with status \(status): \(output)"
        }
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
    private var packageNames: [UUID: String] = [:]

    public var message: String? {
        launchOrder.reversed().compactMap { messages[$0] }.first
    }

    public init() {}

    @discardableResult
    public mutating func beginLaunch(packageName: String, identifier: UUID = UUID()) -> UUID {
        let supersededLaunches = launchOrder.filter { packageNames[$0] == packageName }
        for supersededIdentifier in supersededLaunches {
            removeLaunch(supersededIdentifier)
        }
        launchOrder.removeAll { $0 == identifier }
        launchOrder.append(identifier)
        messages[identifier] = "Launching \(packageName)…"
        packageNames[identifier] = packageName
        return identifier
    }

    public mutating func completeLaunch(
        identifier: UUID,
        result: Result<Void, PackageLaunchError>
    ) {
        guard packageNames[identifier] != nil else {
            return
        }
        if let message = packageLaunchCompletionMessage(for: result) {
            messages[identifier] = message
        } else {
            removeLaunch(identifier)
        }
    }

    public mutating func failToStart(identifier: UUID, message: String) {
        guard packageNames[identifier] != nil else {
            return
        }
        messages[identifier] = message
    }

    private mutating func removeLaunch(_ identifier: UUID) {
        messages[identifier] = nil
        packageNames[identifier] = nil
        launchOrder.removeAll { $0 == identifier }
    }
}

public final class PackageLauncher: @unchecked Sendable {
    static let maximumCapturedOutputBytes = 64 * 1024

    private let lock = NSLock()
    private var runningProcesses: [UUID: Process] = [:]
    private var outputCaptures: [UUID: LauncherOutputCapture] = [:]

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
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [package.launcherURL.path]
        process.currentDirectoryURL = package.directoryURL
        process.standardOutput = outputCapture.pipe
        process.standardError = outputCapture.pipe
        process.terminationHandler = { [weak self] process in
            self?.removeProcess(identifier)

            guard process.terminationStatus != 0 else {
                completion(.success(()))
                return
            }

            completion(.failure(.unsuccessfulExit(
                package: package.displayName,
                status: process.terminationStatus,
                output: outputCapture.finalString()
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
    let pipe = Pipe()

    private let output: BoundedProcessOutput
    private let readLock = NSLock()
    private let onEnd: @Sendable () -> Void
    private var didEnd = false

    init(maximumBytes: Int, onEnd: @escaping @Sendable () -> Void) {
        output = BoundedProcessOutput(maximumBytes: maximumBytes)
        self.onEnd = onEnd
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] _ in
            self?.drainAvailableOutput()
        }
    }

    func finalString() -> String {
        let shouldFinish = drainAvailableOutputLocked()
        let string = output.string
        readLock.unlock()
        if shouldFinish {
            finish()
        }
        return string
    }

    func closeParentWriter() {
        try? pipe.fileHandleForWriting.close()
    }

    func cancel() {
        readLock.lock()
        didEnd = true
        readLock.unlock()
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    private func drainAvailableOutput() {
        let shouldFinish = drainAvailableOutputLocked()
        readLock.unlock()
        if shouldFinish {
            finish()
        }
    }

    private func drainAvailableOutputLocked() -> Bool {
        readLock.lock()
        guard !didEnd else {
            return false
        }

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                output.append(Data(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                didEnd = true
                return true
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }
            didEnd = true
            return true
        }
    }

    private func finish() {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        onEnd()
    }
}
