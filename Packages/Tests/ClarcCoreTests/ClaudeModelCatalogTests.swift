import XCTest
@testable import ClarcCore

final class ClaudeModelCatalogTests: XCTestCase {
    func testLoadsActualNamesAndKeepsCLIArguments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarc-model-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("settings.json")
        let settings: [String: Any] = [
            "model": "fable",
            "env": [
                "ANTHROPIC_DEFAULT_FABLE_MODEL": "deepseek-v4-flash-0731[1M]",
                "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "DeepSeek V4 Flash",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "MiniMax-M3[1M]",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "MiniMax M3",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "qwen3.8-max[1M]",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Qwen 3.8 Max",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5.2",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "GLM 5.2",
                "ANTHROPIC_CUSTOM_MODEL_OPTION": "qwen-coder-plus",
                "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Qwen Coder Plus",
            ],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)

        let snapshot = ClaudeModelCatalog.load(from: url)

        XCTAssertEqual(snapshot.defaultArgument, "fable")
        XCTAssertEqual(snapshot.options.first?.displayName, "DeepSeek V4 Flash")
        XCTAssertEqual(snapshot.options.first(where: { $0.argument == "opus" })?.displayName, "MiniMax M3")
        XCTAssertEqual(snapshot.options.first(where: { $0.argument == "qwen-coder-plus" })?.actualModelId, "qwen-coder-plus")
        XCTAssertFalse(snapshot.options.map(\.displayName).contains("Opus"))
    }

    func testMalformedSettingsUseSafeFallback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarc-invalid-settings-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ClaudeModelCatalog.load(from: url), ClaudeModelCatalog.fallback)
    }

    func testDuplicateActualModelsCollapseToOneVisibleOption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarc-model-dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("settings.json")
        let settings: [String: Any] = [
            "model": "opus",
            "env": [
                "ANTHROPIC_DEFAULT_FABLE_MODEL": "same-model",
                "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME": "Shared Model",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "same-model",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "Shared Model",
            ],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)

        let snapshot = ClaudeModelCatalog.load(from: url)
        XCTAssertEqual(snapshot.options.count, 1)
        XCTAssertEqual(snapshot.options.first?.argument, "opus")
        XCTAssertTrue(snapshot.options.first?.isDefault == true)
    }

    func testActualModelIdAsDefaultMapsBackToCLIArgument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clarc-model-actual-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("settings.json")
        let settings: [String: Any] = [
            "env": [
                "ANTHROPIC_MODEL": "MiniMax-M3[1M]",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "MiniMax-M3[1M]",
                "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "MiniMax M3",
            ],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)

        let snapshot = ClaudeModelCatalog.load(from: url)
        XCTAssertEqual(snapshot.defaultArgument, "opus")
        XCTAssertEqual(snapshot.options.first?.displayName, "MiniMax M3")
        XCTAssertTrue(snapshot.options.first?.isDefault == true)
    }
}
