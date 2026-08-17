import AppKit
import MacEntireCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MacEntireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var catalog = PackageCatalog()

    var body: some Scene {
        MenuBarExtra("MacEntire", systemImage: "square.grid.2x2") {
            PackageMenu(catalog: catalog)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct PackageMenu: View {
    @ObservedObject var catalog: PackageCatalog

    var body: some View {
        Group {
            if catalog.packages.isEmpty {
                Text(catalog.statusMessage ?? "No packages configured")
            } else {
                ForEach(catalog.packages) { package in
                    packageRow(package)
                }
            }

            if let statusMessage = catalog.statusMessage, !catalog.packages.isEmpty {
                Divider()
                Text(statusMessage)
            }

            Divider()

            Button {
                catalog.synchronize()
            } label: {
                Label(catalog.isSynchronizing ? "Syncing Packages…" : "Sync Packages", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(catalog.isSynchronizing)

            Button {
                catalog.openPackagesDirectory()
            } label: {
                Label("Open Packages Folder", systemImage: "folder")
            }

            Button {
                catalog.openPackageList()
            } label: {
                Label("Open packages.txt", systemImage: "doc.text")
            }

            Divider()

            Button("Quit MacEntire") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            catalog.refresh()
        }
    }

    @ViewBuilder
    private func packageRow(_ package: ManagedPackage) -> some View {
        switch package.state {
        case .ready:
            Button {
                catalog.launch(package.definition)
            } label: {
                Label(package.definition.displayName, systemImage: "app")
            }
        case .notInstalled:
            Label("\(package.definition.displayName) — Not installed", systemImage: "arrow.down.circle")
        case .unavailable:
            Label("\(package.definition.displayName) — Unavailable", systemImage: "exclamationmark.triangle")
        }
    }
}

@MainActor
private final class PackageCatalog: ObservableObject {
    @Published private(set) var packages: [ManagedPackage] = []
    @Published private(set) var isSynchronizing = false
    @Published private(set) var statusMessage: String?

    private let workspace: PackageWorkspace
    private let synchronizer: PackageSynchronizer

    init(rootDirectory: URL = WorkspaceRoot.resolve()) {
        let workspace = PackageWorkspace(rootDirectory: rootDirectory)
        self.workspace = workspace
        self.synchronizer = PackageSynchronizer(workspace: workspace)
        refresh()
    }

    func refresh() {
        do {
            packages = try workspace.packages()
            if packages.isEmpty {
                statusMessage = "No packages configured"
            } else if statusMessage == "No packages configured" {
                statusMessage = nil
            }
        } catch {
            packages = []
            statusMessage = error.localizedDescription
        }
    }

    func synchronize() {
        guard !isSynchronizing else {
            return
        }

        isSynchronizing = true
        statusMessage = "Syncing packages…"
        let synchronizer = synchronizer

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try synchronizer.synchronizeAll() }
            }.value

            isSynchronizing = false
            switch result {
            case .success(let results):
                let failures = results.filter { !$0.succeeded }
                if failures.isEmpty {
                    statusMessage = "All packages are up to date"
                } else if failures.count == 1, let failure = failures.first {
                    statusMessage = "\(failure.package.displayName): \(failure.errorMessage ?? "Sync failed")"
                } else {
                    statusMessage = "\(failures.count) packages could not be synced"
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
            refresh()
        }
    }

    func launch(_ package: PackageDefinition) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [package.launcherURL.path]
        process.currentDirectoryURL = package.directoryURL

        do {
            try process.run()
            statusMessage = "Launching \(package.displayName)…"
        } catch {
            statusMessage = "Could not launch \(package.displayName): \(error.localizedDescription)"
        }
    }

    func openPackagesDirectory() {
        do {
            try FileManager.default.createDirectory(at: workspace.packagesDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(workspace.packagesDirectory)
        } catch {
            statusMessage = "Could not open Packages: \(error.localizedDescription)"
        }
    }

    func openPackageList() {
        guard NSWorkspace.shared.open(workspace.packageListURL) else {
            statusMessage = "Could not open packages.txt"
            return
        }
    }
}

private enum WorkspaceRoot {
    static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> URL {
        if let configured = environment["MACENTIRE_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }

        if let configured = bundle.object(forInfoDictionaryKey: "MacEntireRoot") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }

        if let root = ancestorContainingPackageList(startingAt: currentDirectory) {
            return root
        }

        if let executableDirectory = bundle.executableURL?.deletingLastPathComponent(),
           let root = ancestorContainingPackageList(startingAt: executableDirectory) {
            return root
        }

        return currentDirectory.standardizedFileURL
    }

    private static func ancestorContainingPackageList(startingAt start: URL) -> URL? {
        var candidate = start.standardizedFileURL

        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("packages.txt").path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                break
            }
            candidate = parent
        }

        return nil
    }
}
