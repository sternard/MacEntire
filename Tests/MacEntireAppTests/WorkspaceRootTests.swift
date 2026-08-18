import Foundation
import XCTest
@testable import MacEntireApp

final class WorkspaceRootTests: XCTestCase {
    func testEnvironmentRootPreservesSurroundingWhitespace() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuredRoot = temporaryDirectory
            .appendingPathComponent(" checkout ", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let resolved = WorkspaceRoot.resolve(
            environment: ["MACENTIRE_ROOT": configuredRoot.path]
        )

        XCTAssertEqual(resolved, configuredRoot.standardizedFileURL)
    }
}
