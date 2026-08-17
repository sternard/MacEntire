import Foundation

public struct PackageDefinition: Identifiable, Hashable, Sendable {
    public let repositoryURL: URL
    public let repositoryName: String
    public let displayName: String
    public let directoryURL: URL

    public var id: String {
        repositoryURL.absoluteString
    }

    public var launcherURL: URL {
        directoryURL.appendingPathComponent("scripts/run-app.sh", isDirectory: false)
    }

    public init(
        repositoryURL: URL,
        repositoryName: String,
        displayName: String,
        directoryURL: URL
    ) {
        self.repositoryURL = repositoryURL
        self.repositoryName = repositoryName
        self.displayName = displayName
        self.directoryURL = directoryURL.standardizedFileURL
    }
}

public enum PackageListError: LocalizedError, Equatable {
    case unreadableFile(String)
    case invalidEntry(line: Int, value: String)
    case duplicateDirectory(line: Int, name: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "Could not read the package list at \(path)."
        case .invalidEntry(let line, let value):
            return "Invalid package URL on line \(line): \(value)"
        case .duplicateDirectory(let line, let name):
            return "Package directory \(name) is repeated on line \(line)."
        }
    }
}

public struct PackageListParser: Sendable {
    public init() {}

    public func parse(_ contents: String, packagesDirectory: URL) throws -> [PackageDefinition] {
        var packages: [PackageDefinition] = []
        var directoryNames = Set<String>()

        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else {
                continue
            }

            let value = markdownDestination(in: line) ?? line
            guard let parsed = parseGitHubURL(value) else {
                throw PackageListError.invalidEntry(line: lineNumber, value: line)
            }

            guard directoryNames.insert(parsed.repositoryName.lowercased()).inserted else {
                throw PackageListError.duplicateDirectory(line: lineNumber, name: parsed.repositoryName)
            }

            packages.append(PackageDefinition(
                repositoryURL: parsed.url,
                repositoryName: parsed.repositoryName,
                displayName: humanized(parsed.repositoryName),
                directoryURL: packagesDirectory.appendingPathComponent(parsed.repositoryName, isDirectory: true)
            ))
        }

        return packages
    }

    private func markdownDestination(in line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix(")"), let separator = line.range(of: "](") else {
            return nil
        }

        return String(line[separator.upperBound..<line.index(before: line.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseGitHubURL(_ value: String) -> (url: URL, repositoryName: String)? {
        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "github.com",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }

        let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count == 2 else {
            return nil
        }

        var repositoryName = String(pathComponents[1])
        if repositoryName.lowercased().hasSuffix(".git") {
            repositoryName.removeLast(4)
        }

        guard !repositoryName.isEmpty, repositoryName != ".", repositoryName != ".." else {
            return nil
        }

        var canonical = components
        canonical.scheme = "https"
        canonical.host = "github.com"
        canonical.path = "/\(pathComponents[0])/\(repositoryName)"

        guard let url = canonical.url else {
            return nil
        }

        return (url, repositoryName)
    }

    private func humanized(_ repositoryName: String) -> String {
        repositoryName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                String(word.prefix(1)).uppercased() + String(word.dropFirst())
            }
            .joined(separator: " ")
    }
}
