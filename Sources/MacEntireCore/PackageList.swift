import Foundation

public struct PackageDefinition: Identifiable, Hashable, Sendable {
    public let repositoryURL: URL
    public let repositoryName: String
    public let displayName: String
    public let branch: String?
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
        branch: String? = nil,
        directoryURL: URL
    ) {
        self.repositoryURL = repositoryURL
        self.repositoryName = repositoryName
        self.displayName = displayName
        self.branch = branch
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
            return "Invalid package entry on line \(line): \(value)"
        case .duplicateDirectory(let line, let name):
            return "Package directory \(name) is repeated on line \(line)."
        }
    }
}

public struct PackageListParser: Sendable {
    static let packageListFilename = "packages.txt"
    private static let reservedPackageDirectoryNames: Set<String> = [
        packageListFilename,
        ".gitkeep"
    ]

    public init() {}

    public func parse(_ contents: String, packagesDirectory: URL) throws -> [PackageDefinition] {
        var packages: [PackageDefinition] = []
        var directoryNames = Set<String>()

        for (offset, rawLine) in contents.split(
            maxSplits: .max,
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else {
                continue
            }

            guard
                let entry = parseEntry(line),
                let parsed = parseGitHubURL(entry.repository)
            else {
                throw PackageListError.invalidEntry(line: lineNumber, value: line)
            }

            let normalizedDirectoryName = parsed.repositoryName.lowercased()
            guard !Self.reservedPackageDirectoryNames.contains(normalizedDirectoryName) else {
                throw PackageListError.invalidEntry(line: lineNumber, value: line)
            }

            guard directoryNames.insert(normalizedDirectoryName).inserted else {
                throw PackageListError.duplicateDirectory(line: lineNumber, name: parsed.repositoryName)
            }

            packages.append(PackageDefinition(
                repositoryURL: parsed.url,
                repositoryName: parsed.repositoryName,
                displayName: humanized(parsed.repositoryName),
                branch: entry.branch,
                directoryURL: packagesDirectory.appendingPathComponent(parsed.repositoryName, isDirectory: true)
            ))
        }

        return packages
    }

    private func parseEntry(_ line: String) -> (repository: String, branch: String?)? {
        let repository: String
        let optionTokens: [Substring]

        if line.hasPrefix("[") {
            guard
                let separator = line.range(of: "]("),
                let closingParenthesis = line[separator.upperBound...].firstIndex(of: ")")
            else {
                return nil
            }

            repository = String(line[separator.upperBound..<closingParenthesis])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            optionTokens = line[line.index(after: closingParenthesis)...]
                .split(whereSeparator: { $0.isWhitespace })
        } else {
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = tokens.first else {
                return nil
            }
            repository = String(first)
            optionTokens = Array(tokens.dropFirst())
        }

        guard !repository.isEmpty else {
            return nil
        }

        if optionTokens.isEmpty {
            return (repository, nil)
        }

        guard
            optionTokens.count == 2,
            optionTokens[0] == "-b"
        else {
            return nil
        }

        let branch = String(optionTokens[1])
        guard isValidBranchName(branch) else {
            return nil
        }

        return (repository, branch)
    }

    private func isValidBranchName(_ branch: String) -> Bool {
        let forbiddenCharacters = CharacterSet(charactersIn: " ~^:?*[\\")
        let components = branch.split(separator: "/", omittingEmptySubsequences: false)

        return !branch.isEmpty
            && branch != "@"
            && branch != "HEAD"
            && !branch.hasPrefix("-")
            && !branch.hasPrefix("refs/")
            && !branch.hasSuffix(".")
            && !branch.contains("..")
            && !branch.contains("@{")
            && branch.rangeOfCharacter(from: forbiddenCharacters) == nil
            && branch.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
            && components.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
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

        let ownerName = String(pathComponents[0])
        guard ownerName != ".", ownerName != ".." else {
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
        canonical.path = "/\(ownerName)/\(repositoryName)"

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
