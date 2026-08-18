import Foundation
import XCTest

final class InstallerScriptTests: XCTestCase {
    func testFailedReplacementCopyPreservesInstalledBundle() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = temporaryDirectory.appendingPathComponent("repository", isDirectory: true)
        let scriptsDirectory = repository.appendingPathComponent("scripts", isDirectory: true)
        let buildDirectory = repository.appendingPathComponent(".build/release", isDirectory: true)
        let homeDirectory = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
        let installDirectory = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        let installedBundle = installDirectory.appendingPathComponent("MacEntire.app", isDirectory: true)
        let sentinel = installedBundle.appendingPathComponent("sentinel.txt", isDirectory: false)
        let stubDirectory = temporaryDirectory.appendingPathComponent("bin", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installedBundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        let sourceRepository = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceInstaller = sourceRepository.appendingPathComponent("scripts/install-app.sh", isDirectory: false)
        let installer = scriptsDirectory.appendingPathComponent("install-app.sh", isDirectory: false)
        try fileManager.copyItem(at: sourceInstaller, to: installer)
        try Data("new executable".utf8).write(
            to: buildDirectory.appendingPathComponent("MacEntireApp", isDirectory: false)
        )
        try Data("working installation".utf8).write(to: sentinel)

        for command in ["swift", "codesign", "plutil", "open"] {
            try writeExecutable(
                "#!/usr/bin/env bash\nexit 0\n",
                to: stubDirectory.appendingPathComponent(command, isDirectory: false)
            )
        }
        try writeExecutable(
            """
            #!/usr/bin/env bash
            destination="${@: -1}"
            case "$destination" in
                */.MacEntire.install.*/MacEntire.app) exit 73 ;;
            esac
            exec /bin/cp "$@"
            """,
            to: stubDirectory.appendingPathComponent("cp", isDirectory: false)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash", isDirectory: false)
        process.arguments = [installer.path]
        process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory.path
        environment["MACENTIRE_INSTALL_DIR"] = installDirectory.path
        environment["PATH"] = "\(stubDirectory.path):\(environment["PATH"] ?? "")"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "working installation")
        XCTAssertFalse(
            try fileManager.contentsOfDirectory(atPath: installDirectory.path)
                .contains(where: { $0.hasPrefix(".MacEntire.install.") })
        )
    }

    func testNestedFinalMoveRestoresInstalledBundle() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = temporaryDirectory.appendingPathComponent("repository", isDirectory: true)
        let scriptsDirectory = repository.appendingPathComponent("scripts", isDirectory: true)
        let buildDirectory = repository.appendingPathComponent(".build/release", isDirectory: true)
        let homeDirectory = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
        let installDirectory = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        let installedBundle = installDirectory.appendingPathComponent("MacEntire.app", isDirectory: true)
        let sentinel = installedBundle.appendingPathComponent("sentinel.txt", isDirectory: false)
        let stubDirectory = temporaryDirectory.appendingPathComponent("bin", isDirectory: true)
        let moveCount = temporaryDirectory.appendingPathComponent("move-count", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installedBundle, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stubDirectory, withIntermediateDirectories: true)

        let sourceRepository = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceInstaller = sourceRepository.appendingPathComponent("scripts/install-app.sh", isDirectory: false)
        let installer = scriptsDirectory.appendingPathComponent("install-app.sh", isDirectory: false)
        try fileManager.copyItem(at: sourceInstaller, to: installer)
        try Data("new executable".utf8).write(
            to: buildDirectory.appendingPathComponent("MacEntireApp", isDirectory: false)
        )
        try Data("working installation".utf8).write(to: sentinel)

        for command in ["swift", "codesign", "plutil", "open"] {
            try writeExecutable(
                "#!/usr/bin/env bash\nexit 0\n",
                to: stubDirectory.appendingPathComponent(command, isDirectory: false)
            )
        }
        try writeExecutable(
            """
            #!/usr/bin/env bash
            count=0
            if [[ -f "$MACENTIRE_TEST_MOVE_COUNT" ]]; then
                count="$(cat "$MACENTIRE_TEST_MOVE_COUNT")"
            fi
            count=$((count + 1))
            echo "$count" > "$MACENTIRE_TEST_MOVE_COUNT"
            if [[ "$count" == 2 ]]; then
                destination="${@: -1}"
                /bin/mkdir -p "$destination"
            fi
            exec /bin/mv "$@"
            """,
            to: stubDirectory.appendingPathComponent("mv", isDirectory: false)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash", isDirectory: false)
        process.arguments = [installer.path]
        process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory.path
        environment["MACENTIRE_INSTALL_DIR"] = installDirectory.path
        environment["MACENTIRE_TEST_MOVE_COUNT"] = moveCount.path
        environment["PATH"] = "\(stubDirectory.path):\(environment["PATH"] ?? "")"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "working installation")
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: installedBundle.appendingPathComponent("MacEntire.app").path
            )
        )
        let recoveryDirectory = try XCTUnwrap(
            fileManager.contentsOfDirectory(atPath: installDirectory.path)
                .first(where: { $0.hasPrefix(".MacEntire.install.") })
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: installDirectory
                    .appendingPathComponent(recoveryDirectory, isDirectory: true)
                    .appendingPathComponent("conflicting-MacEntire.app/MacEntire.app", isDirectory: true)
                    .path
            )
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
