import XCTest
@testable import ClarcCore

final class CLIProjectDiscoveryTests: XCTestCase {
    func testDiscoversExistingCwdsAndSkipsMissingAndNestedSubagents() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarc-project-discovery-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = sandbox.appendingPathComponent("projects", isDirectory: true)
        let workspaceA = sandbox.appendingPathComponent("Workspace A", isDirectory: true)
        let workspaceB = sandbox.appendingPathComponent("home-like", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try makeCLIProject(named: "encoded-a", cwd: workspaceA.path, under: projectsRoot)
        try makeCLIProject(named: "encoded-b", cwd: workspaceB.path + "/", under: projectsRoot)
        try makeCLIProject(named: "missing", cwd: sandbox.appendingPathComponent("gone").path, under: projectsRoot)

        // A broader cwd can appear before the workspace cwd in a resumed file;
        // discovery must prefer the more specific encoded match.
        let misleadingURL = projectsRoot
            .appendingPathComponent("encoded-a", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        let broad = try JSONSerialization.data(withJSONObject: ["cwd": sandbox.path])
        let specific = try JSONSerialization.data(withJSONObject: ["cwd": workspaceA.path])
        try (broad + Data("\n".utf8) + specific).write(to: misleadingURL)

        let nested = projectsRoot
            .appendingPathComponent("encoded-a", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("{\"cwd\":\"/should/not/be/a/project\"}\n".utf8)
            .write(to: nested.appendingPathComponent("agent.jsonl"))

        let store = CLISessionStore(metaStore: SessionMetaStore(), projectsRootURL: projectsRoot)
        let discovered = await store.discoverProjects(forceRefresh: true)

        XCTAssertEqual(Set(discovered.map(\.cwd)), Set([
            workspaceA.path.standardizedCwd(),
            workspaceB.path.standardizedCwd(),
        ]))
        XCTAssertTrue(discovered.allSatisfy { $0.cliDirectory.deletingLastPathComponent() == projectsRoot })
    }

    func testForceRefreshAddsNewDirectoryWithoutResniffingKnownOnes() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarc-project-refresh-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = sandbox.appendingPathComponent("projects", isDirectory: true)
        let workspaceA = sandbox.appendingPathComponent("A", isDirectory: true)
        let workspaceB = sandbox.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try makeCLIProject(named: "a", cwd: workspaceA.path, under: projectsRoot)
        let store = CLISessionStore(metaStore: SessionMetaStore(), projectsRootURL: projectsRoot)
        let initial = await store.discoverProjects(forceRefresh: true)
        XCTAssertEqual(initial.count, 1)

        try makeCLIProject(named: "b", cwd: workspaceB.path, under: projectsRoot)
        let refreshed = await store.discoverProjects(forceRefresh: true)
        XCTAssertEqual(refreshed.count, 2)
    }

    private func makeCLIProject(named name: String, cwd: String, under root: URL) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encodedCwd = try JSONSerialization.data(withJSONObject: ["cwd": cwd])
        try encodedCwd.write(to: directory.appendingPathComponent("session.jsonl"))
    }
}
