import Foundation

public actor PackageInspector {
    private let workspace: PackageWorkspace
    private let gitRunner: any GitRunning
    private var inFlightInspection: Task<[ManagedPackage], Error>?

    public init(
        workspace: PackageWorkspace,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) {
        self.workspace = workspace
        self.gitRunner = gitRunner
    }

    public func packages() async throws -> [ManagedPackage] {
        if let inFlightInspection {
            return try await inFlightInspection.value
        }

        let workspace = workspace
        let gitRunner = gitRunner
        let inspection = Task.detached(priority: .userInitiated) {
            try workspace.packages(gitRunner: gitRunner)
        }
        inFlightInspection = inspection
        defer { inFlightInspection = nil }
        return try await inspection.value
    }
}
