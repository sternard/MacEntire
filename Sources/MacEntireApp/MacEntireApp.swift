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
                Label(
                    catalog.isSynchronizing ? "Syncing Packages…" : "Sync Packages",
                    systemImage: "arrow.triangle.2.circlepath"
                )
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
                catalog.launch(package)
            } label: {
                Label(package.displayTitle, systemImage: "app")
            }
            .disabled(!catalog.canLaunch(package))
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
    @Published private(set) var isSynchronizing = false
    @Published private(set) var statusMessage: String?
    @Published private var runningProcesses: [String: Process] = [:]

    var canSynchronize: Bool {
        !isSynchronizing && runningProcesses.isEmpty
    }

    private let workspace: PackageWorkspace
    private let synchronizer: PackageSynchronizer
    private let pendingReinstallationStore: PendingReinstallationStore
    private var refreshGeneration = 0
    private var statusMessageIsInspectionError = false
    private var launchFailure: (packageID: String, message: String)?

    init(
        rootDirectory: URL = WorkspaceRoot.resolve(),
        pendingReinstallationStore: PendingReinstallationStore = PendingReinstallationStore()
    ) {
        let workspace = PackageWorkspace(rootDirectory: rootDirectory)
        self.workspace = workspace
        self.synchronizer = PackageSynchronizer(workspace: workspace)
        self.pendingReinstallationStore = pendingReinstallationStore
        self.statusMessage = pendingReinstallationStore.statusMessage(for: rootDirectory)
        refresh()
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let workspace = workspace

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try workspace.packages() }
            }.value
            guard generation == refreshGeneration else {
                return
            }

            switch result {
            case .success(let inspectedPackages):
                packages = inspectedPackages.sorted {
                    $0.definition.displayName.localizedCaseInsensitiveCompare(
                        $1.definition.displayName
                    ) == .orderedAscending
                }
                if statusMessageIsInspectionError {
                    statusMessage = pendingReinstallationStore.statusMessage(
                        for: workspace.rootDirectory
                    )
                    statusMessageIsInspectionError = false
                }
                if packages.isEmpty, statusMessage == nil {
                    statusMessage = "No packages configured"
                } else if !packages.isEmpty, statusMessage == "No packages configured" {
                    statusMessage = nil
                }
            case .failure(let error):
                packages = []
                statusMessage = error.localizedDescription
                statusMessageIsInspectionError = true
            }
        }
    }

    func synchronize() {
        guard canSynchronize else {
            return
        }

        isSynchronizing = true
        statusMessage = "Syncing MacEntire and packages…"
        statusMessageIsInspectionError = false
        let synchronizer = synchronizer

        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                synchronizer.synchronizeAll()
            }.value

            var message = summary.statusMessage
            if summary.macEntireUpdated {
                do {
                    try pendingReinstallationStore.markRequired(
                        for: workspace.rootDirectory
                    )
                } catch {
                    message += "; could not save the reinstall reminder: "
                        + error.localizedDescription
                }
            } else if let pendingMessage = pendingReinstallationStore.statusMessage(
                for: workspace.rootDirectory
            ) {
                message = "\(pendingMessage); \(message)"
            }

            statusMessage = message
            statusMessageIsInspectionError = false
            packages = []
            isSynchronizing = false
            refresh()
        }
    }

    func canLaunch(_ package: ManagedPackage) -> Bool {
        package.state == .ready
            && !isSynchronizing
            && runningProcesses[package.id] == nil
    }

    func launch(_ package: ManagedPackage) {
        guard canLaunch(package) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [package.definition.launcherURL.path]
        process.currentDirectoryURL = package.definition.directoryURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                runningProcesses[package.id] = nil
                if process.terminationStatus != 0 {
                    let message = "Could not launch \(package.definition.displayName) "
                        + "(exit status \(process.terminationStatus))"
                    statusMessage = message
                    statusMessageIsInspectionError = false
                    launchFailure = (package.id, message)
                } else if let failure = launchFailure,
                          failure.packageID == package.id {
                    if statusMessage == failure.message {
                        statusMessage = pendingReinstallationStore.statusMessage(
                            for: workspace.rootDirectory
                        )
                    }
                    launchFailure = nil
                }
            }
        }

        runningProcesses[package.id] = process
        do {
            try process.run()
        } catch {
            runningProcesses[package.id] = nil
            let message = "Could not launch \(package.definition.displayName): "
                + error.localizedDescription
            statusMessage = message
            statusMessageIsInspectionError = false
            launchFailure = (package.id, message)
        }
    }

    func openPackagesDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: workspace.packagesDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(workspace.packagesDirectory)
        } catch {
            statusMessage = "Could not open Packages: \(error.localizedDescription)"
            statusMessageIsInspectionError = false
        }
    }
}

enum WorkspaceRoot {
    static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) -> URL {
        if let configured = environment["MACENTIRE_ROOT"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }

        if let configured = bundle.object(forInfoDictionaryKey: "MacEntireRoot") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return currentDirectory.standardizedFileURL
    }
}
