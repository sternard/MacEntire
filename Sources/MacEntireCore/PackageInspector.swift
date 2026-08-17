import Foundation

public actor PackageInspector {
    private struct InFlightInspection {
        let identifier: UUID
        let task: Task<[ManagedPackage], Error>
    }

    private let workspace: PackageWorkspace
    private let gitRunner: any GitRunning
    private var inFlightInspection: InFlightInspection?

    public init(
        workspace: PackageWorkspace,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) {
        self.workspace = workspace
        self.gitRunner = gitRunner
    }

    public func packages(forceRefresh: Bool = false) async throws -> [ManagedPackage] {
        if let inFlightInspection {
            guard forceRefresh else {
                return try await inFlightInspection.task.value
            }

            _ = try? await inFlightInspection.task.value
            if let newerInspection = self.inFlightInspection,
               newerInspection.identifier != inFlightInspection.identifier {
                return try await newerInspection.task.value
            }
        }

        return try await startInspection()
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
