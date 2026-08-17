import AppKit
import MacEntireCore
import ServiceManagement
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
    @StateObject private var loginItem = LoginItemController()

    var body: some Scene {
        MenuBarExtra("MacEntire", systemImage: "square.grid.2x2") {
            PackageMenu(catalog: catalog, loginItem: loginItem)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct PackageMenu: View {
    @ObservedObject var catalog: PackageCatalog
    @ObservedObject var loginItem: LoginItemController

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
            .disabled(!catalog.canSynchronize)

            Button {
                catalog.openPackagesDirectory()
            } label: {
                Label("Open Packages Folder", systemImage: "folder")
            }

            Divider()

            Button {
                loginItem.setEnabled(!loginItem.isEnabled)
            } label: {
                Label(
                    "Start on Login",
                    systemImage: loginItem.isEnabled ? "checkmark" : "xmark"
                )
            }

            if let statusMessage = loginItem.statusMessage {
                Text(statusMessage)
            }

            Divider()

            Button("Quit MacEntire") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            catalog.refresh()
            loginItem.refresh()
        }
    }

    @ViewBuilder
    private func packageRow(_ package: ManagedPackage) -> some View {
        switch package.state {
        case .ready:
            Button {
                catalog.launch(package.definition)
            } label: {
                Label(package.displayTitle, systemImage: "app")
            }
            .disabled(!package.isLaunchEnabled(whileSynchronizing: catalog.isSynchronizing))
        case .notInstalled:
            Label(package.displayTitle, systemImage: "arrow.down.circle")
        case .unavailable:
            Label(package.displayTitle, systemImage: "exclamationmark.triangle")
        }
    }
}

@MainActor
private final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = nil
        case .requiresApproval:
            isEnabled = true
            statusMessage = "Approval required in System Settings → General → Login Items"
        case .notRegistered:
            isEnabled = false
            statusMessage = nil
        case .notFound:
            isEnabled = false
            statusMessage = "Login item is unavailable for this app"
        @unknown default:
            isEnabled = false
            statusMessage = "Login item status is unavailable"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusMessage = "Could not update Start on Login: \(error.localizedDescription)"
        }
    }
}

@MainActor
private final class PackageCatalog: ObservableObject {
    @Published private(set) var packages: [ManagedPackage] = []
    @Published private(set) var statusMessage: String?
    @Published private var operationState = PackageOperationState()

    var isSynchronizing: Bool {
        operationState.isSynchronizing
    }

    var canSynchronize: Bool {
        operationState.canSynchronize
    }

    private let workspace: PackageWorkspace
    private let inspector: PackageInspector
    private let synchronizer: PackageSynchronizer
    private let launcher = PackageLauncher()
    private var refreshGeneration = 0

    init(rootDirectory: URL = WorkspaceRoot.resolve()) {
        let workspace = PackageWorkspace(rootDirectory: rootDirectory)
        self.workspace = workspace
        self.inspector = PackageInspector(workspace: workspace)
        self.synchronizer = PackageSynchronizer(workspace: workspace)
        refresh()
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let inspector = inspector

        Task {
            do {
                let inspectedPackages = try await inspector.packages()
                guard generation == refreshGeneration else {
                    return
                }
                packages = inspectedPackages.sorted {
                    $0.definition.displayName.localizedCaseInsensitiveCompare($1.definition.displayName) == .orderedAscending
                }
                if packages.isEmpty {
                    statusMessage = "No packages configured"
                } else if statusMessage == "No packages configured" {
                    statusMessage = nil
                }
            } catch {
                guard generation == refreshGeneration else {
                    return
                }
                packages = []
                statusMessage = error.localizedDescription
            }
        }
    }

    func synchronize() {
        guard operationState.beginSynchronization() else {
            return
        }

        statusMessage = "Syncing MacEntire and packages…"
        let synchronizer = synchronizer

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try synchronizer.synchronizeAll() }
            }.value

            operationState.endSynchronization()
            switch result {
            case .success(let summary):
                let failures = summary.packageResults.filter { !$0.succeeded }
                if let macEntireErrorMessage = summary.macEntireErrorMessage {
                    if failures.isEmpty {
                        statusMessage = "MacEntire: \(macEntireErrorMessage)"
                    } else {
                        statusMessage = "MacEntire and \(failures.count) package updates could not be synced"
                    }
                } else if failures.isEmpty {
                    statusMessage = "MacEntire and all packages are up to date"
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
        guard operationState.beginLaunch() else {
            return
        }

        do {
            try launcher.launch(package) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    operationState.endLaunch()
                    statusMessage = packageLaunchCompletionMessage(for: result)
                }
            }
            statusMessage = "Launching \(package.displayName)…"
        } catch {
            operationState.endLaunch()
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
            let packageList = candidate
                .appendingPathComponent("Packages", isDirectory: true)
                .appendingPathComponent("packages.txt", isDirectory: false)
            if FileManager.default.fileExists(atPath: packageList.path) {
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
