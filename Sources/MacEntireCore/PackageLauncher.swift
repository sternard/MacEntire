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

public final class PackageLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var runningProcesses: [UUID: Process] = [:]

    public init() {}

    public func launch(
        _ package: PackageDefinition,
        completion: @escaping @Sendable (Result<Void, PackageLaunchError>) -> Void
    ) throws {
        let identifier = UUID()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEntireLauncher-\(identifier.uuidString).log", isDirectory: false)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [package.launcherURL.path]
        process.currentDirectoryURL = package.directoryURL
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.terminationHandler = { [weak self] process in
            try? outputHandle.close()
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            try? FileManager.default.removeItem(at: outputURL)
            self?.removeProcess(identifier)

            guard process.terminationStatus != 0 else {
                completion(.success(()))
                return
            }

            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.failure(.unsuccessfulExit(
                package: package.displayName,
                status: process.terminationStatus,
                output: output
            )))
        }

        storeProcess(process, identifier: identifier)
        do {
            try process.run()
        } catch {
            removeProcess(identifier)
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func storeProcess(_ process: Process, identifier: UUID) {
        lock.lock()
        runningProcesses[identifier] = process
        lock.unlock()
    }

    private func removeProcess(_ identifier: UUID) {
        lock.lock()
        runningProcesses[identifier] = nil
        lock.unlock()
    }
}
