import XCTest
@testable import ClarcCore

final class ProjectCodableTests: XCTestCase {
    func testLegacyProjectWithoutPinnedFieldDecodesAsUnpinned() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Legacy",
          "path": "/tmp/legacy",
          "gitHubRepo": "owner/repo",
          "lastSessionId": "session-1"
        }
        """

        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.id, id)
        XCTAssertEqual(project.name, "Legacy")
        XCTAssertEqual(project.path, "/tmp/legacy")
        XCTAssertEqual(project.gitHubRepo, "owner/repo")
        XCTAssertEqual(project.lastSessionId, "session-1")
        XCTAssertFalse(project.isPinned)
    }

    func testPinnedProjectRoundTrips() throws {
        let project = Project(
            name: "Pinned",
            path: "/tmp/pinned",
            gitHubRepo: nil,
            lastSessionId: "session-2",
            isPinned: true
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertTrue(decoded.isPinned)
    }

    func testSidebarOrderingGroupsPinnedThenUsesRecentActivity() {
        let pinnedOld = Project(name: "Pinned Old", path: "/tmp/pinned-old", isPinned: true)
        let pinnedNew = Project(name: "Pinned New", path: "/tmp/pinned-new", isPinned: true)
        let regularOld = Project(name: "Regular Old", path: "/tmp/regular-old")
        let regularNew = Project(name: "Regular New", path: "/tmp/regular-new")
        let now = Date()
        let activity = [
            pinnedOld.id: now.addingTimeInterval(-60),
            pinnedNew.id: now,
            regularOld.id: now.addingTimeInterval(-120),
            regularNew.id: now.addingTimeInterval(60),
        ]

        let result = Project.sortedForSidebar(
            [regularOld, pinnedOld, regularNew, pinnedNew],
            latestActivityByProject: activity
        )

        XCTAssertEqual(result.map(\.id), [pinnedNew.id, pinnedOld.id, regularNew.id, regularOld.id])
    }

    func testSidebarOrderingSortsProjectsWithoutActivityByNameWithinGroup() {
        let beta = Project(name: "Beta", path: "/tmp/beta")
        let alpha = Project(name: "Alpha", path: "/tmp/alpha")

        let result = Project.sortedForSidebar(
            [beta, alpha],
            latestActivityByProject: [:]
        )

        XCTAssertEqual(result.map(\.id), [alpha.id, beta.id])
    }
}
