import Foundation

public struct PendingReinstallationStore: Sendable {
    public static let statusMessage = "MacEntire updated — quit and run scripts/install-app.sh to install it"

    public let markerURL: URL

    public init() {
        markerURL = Self.defaultMarkerURL
    }

    public init(markerURL: URL) {
        self.markerURL = markerURL
    }

    public func statusMessage(for rootDirectory: URL) -> String? {
        guard
            let data = try? Data(contentsOf: markerURL),
            data == markerData(for: rootDirectory)
        else {
            return nil
        }
        return Self.statusMessage
    }

    public func markRequired(for rootDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markerData(for: rootDirectory).write(to: markerURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: markerURL)
    }

    private func markerData(for rootDirectory: URL) -> Data {
        Data(rootDirectory.standardizedFileURL.path.utf8)
    }

    private static var defaultMarkerURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("MacEntire", isDirectory: true)
            .appendingPathComponent("reinstall-required", isDirectory: false)
    }
}
