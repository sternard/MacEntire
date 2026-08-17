import Foundation

public struct PackageInspector: Sendable {
    private let workspace: PackageWorkspace
    private let gitRunner: any GitRunning

    public init(
        workspace: PackageWorkspace,
        gitRunner: any GitRunning = ProcessGitRunner()
    ) {
        self.workspace = workspace
        self.gitRunner = gitRunner
    }

    public func packages() async throws -> [ManagedPackage] {
        let workspace = workspace
        let gitRunner = gitRunner
        return try await Task.detached(priority: .userInitiated) {
            try workspace.packages(gitRunner: gitRunner)
        }.value
    }
}
