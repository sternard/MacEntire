import Foundation

public enum PackageState: Equatable, Sendable {
    case notInstalled
    case ready
    case unavailable(String)
}

public struct ManagedPackage: Identifiable, Equatable, Sendable {
    public let definition: PackageDefinition
    public let state: PackageState

    public var id: String {
        definition.id
    }

    public init(definition: PackageDefinition, state: PackageState) {
        self.definition = definition
        self.state = state
    }
}

public struct PackageWorkspace: Sendable {
    public let rootDirectory: URL
    public let packageListURL: URL
    public let packagesDirectory: URL

    public init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        let packagesDirectory = root.appendingPathComponent("Packages", isDirectory: true)
        self.rootDirectory = root
        self.packageListURL = packagesDirectory.appendingPathComponent("packages.txt", isDirectory: false)
        self.packagesDirectory = packagesDirectory
    }

    public func definitions() throws -> [PackageDefinition] {
        guard let contents = try? String(contentsOf: packageListURL, encoding: .utf8) else {
            throw PackageListError.unreadableFile(packageListURL.path)
        }

        return try PackageListParser().parse(contents, packagesDirectory: packagesDirectory)
    }

    public func packages(fileManager: FileManager = .default) throws -> [ManagedPackage] {
        try definitions().map { definition in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: definition.directoryURL.path, isDirectory: &isDirectory) else {
                return ManagedPackage(definition: definition, state: .notInstalled)
            }

            guard isDirectory.boolValue else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package path is not a directory")
                )
            }

            guard fileManager.fileExists(atPath: definition.directoryURL.appendingPathComponent(".git").path) else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("The package folder is not a Git repository")
                )
            }

            var launcherIsDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: definition.launcherURL.path, isDirectory: &launcherIsDirectory),
                !launcherIsDirectory.boolValue
            else {
                return ManagedPackage(
                    definition: definition,
                    state: .unavailable("Missing scripts/run-app.sh")
                )
            }

            return ManagedPackage(definition: definition, state: .ready)
        }
    }
}
