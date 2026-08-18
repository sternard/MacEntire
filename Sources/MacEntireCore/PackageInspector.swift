import Foundation

public actor PackageInspector {
    private struct InFlightInspection {
        let identifier: UUID
        let task: Task<[ManagedPackage], Error>
    }

    private let workspace: PackageWorkspace
    private let gitRunner: any GitRunning
    private var inFlightInspection: InFlightInspection?
    private var queuedForcedInspection: InFlightInspection?

    public init(
        workspace: PackageWorkspace,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) {
        self.workspace = workspace
        self.gitRunner = gitRunner
    }

    public func packages(forceRefresh: Bool = false) async throws -> [ManagedPackage] {
        if let queuedForcedInspection {
            return try await queuedForcedInspection.task.value
        }

        if let inFlightInspection {
            guard forceRefresh else {
                return try await inFlightInspection.task.value
            }

            return try await queueForcedInspection(after: inFlightInspection)
        }

        return try await startInspection()
    }

    private func queueForcedInspection(
        after inFlightInspection: InFlightInspection
    ) async throws -> [ManagedPackage] {
        let workspace = workspace
        let gitRunner = gitRunner
        let identifier = UUID()
        let inspection = Task.detached(priority: .userInitiated) {
            _ = try? await inFlightInspection.task.value
            return try workspace.packages(gitRunner: gitRunner)
        }
        queuedForcedInspection = InFlightInspection(identifier: identifier, task: inspection)
        defer {
            if queuedForcedInspection?.identifier == identifier {
                queuedForcedInspection = nil
            }
        }
        return try await inspection.value
    }

    private func startInspection() async throws -> [ManagedPackage] {
        let workspace = workspace
        let gitRunner = gitRunner
        let identifier = UUID()
        let inspection = Task.detached(priority: .userInitiated) {
            try workspace.packages(gitRunner: gitRunner)
        }
        inFlightInspection = InFlightInspection(identifier: identifier, task: inspection)
        defer {
            if inFlightInspection?.identifier == identifier {
                inFlightInspection = nil
            }
        }
        return try await inspection.value
    }
}
