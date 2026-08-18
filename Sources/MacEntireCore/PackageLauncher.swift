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
    private var packageIdentifiers: [UUID: String] = [:]

    public var message: String? {
        launchOrder.reversed().compactMap { messages[$0] }.first
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
        let outputCapture = try LauncherOutputCapture(maximumBytes: Self.maximumCapturedOutputBytes) { [weak self] in
            self?.removeOutputCapture(identifier)
        }
        let process = Process()
        process.executableURL = package.launcherURL
        process.currentDirectoryURL = package.directoryURL
        process.standardOutput = outputCapture.writer
        process.standardError = outputCapture.writer
        process.terminationHandler = { [weak self] process in
            self?.removeProcess(identifier)
            let capturedOutput = outputCapture.finishAndClose()

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
    let writer: FileHandle

    private let fileURL: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private let onEnd: @Sendable () -> Void
    private var writerIsClosed = false
    private var didFinish = false

    init(maximumBytes: Int, onEnd: @escaping @Sendable () -> Void) throws {
        self.maximumBytes = maximumBytes
        self.onEnd = onEnd
        var pathTemplate = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("MacEntire-Launcher-XXXXXX")
                .path
                .utf8CString
        )
        let descriptor = pathTemplate.withUnsafeMutableBufferPointer { buffer in
            Darwin.mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errorCode))]
            )
        }
        fileURL = URL(fileURLWithPath: String(cString: pathTemplate))
        writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func finishAndClose() -> String {
        guard beginFinishing() else {
            return ""
        }
        closeParentWriter()
        defer { onEnd() }

        guard let reader = try? FileHandle(forReadingFrom: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            return ""
        }
        try? FileManager.default.removeItem(at: fileURL)
        defer { try? reader.close() }

        guard let endOffset = try? reader.seekToEnd() else {
            return ""
        }
        let bytesToRead = min(endOffset, UInt64(maximumBytes))
        try? reader.seek(toOffset: endOffset - bytesToRead)
        let data = (try? reader.readToEnd()) ?? Data()
        let output = BoundedProcessOutput(maximumBytes: maximumBytes)
        output.append(data)
        return output.string
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
        guard beginFinishing() else {
            return
        }
        closeParentWriter()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func beginFinishing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else {
            return false
        }
        didFinish = true
        return true
    }
}
