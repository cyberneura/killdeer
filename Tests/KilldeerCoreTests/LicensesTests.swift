import Foundation
import XCTest
@testable import KilldeerCore

/// `Licenses` is generated from files at the root of the repository and compiled
/// into both executables. These catch the generated copy falling behind them,
/// which would ship a notice that no longer matches the files next to the code.
final class LicensesTests: XCTestCase {
    func testEmbeddedLicenseMatchesTheLicenseFile() throws {
        // Arrange
        let file = try repositoryFile("LICENSE")

        // Act
        let embedded = Licenses.license

        // Assert
        XCTAssertEqual(embedded, file, "Run scripts/generate-third-party-notices.sh and commit the result.")
    }

    func testEmbeddedNoticesMatchTheNoticesFile() throws {
        // Arrange
        let file = try repositoryFile("THIRD-PARTY-NOTICES.txt")

        // Act
        let embedded = Licenses.thirdPartyNotices

        // Assert
        XCTAssertEqual(embedded, file, "Run scripts/generate-third-party-notices.sh and commit the result.")
    }

    func testNoticesStartWithTheirHeading() {
        XCTAssertTrue(Licenses.thirdPartyNotices.hasPrefix("THIRD-PARTY NOTICES\n"))
        XCTAssertTrue(Licenses.license.hasPrefix("MIT License\n"))
    }

    /// Read through this file's own path: Tests/KilldeerCoreTests/<file> is two
    /// levels below the repository root. Line endings are normalised because a
    /// Windows checkout with autocrlf would otherwise fail on every line.
    private func repositoryFile(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
