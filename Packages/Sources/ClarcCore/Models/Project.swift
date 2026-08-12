import Foundation

public struct Project: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var path: String
    public var gitHubRepo: String?
    public var lastSessionId: String?
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        gitHubRepo: String? = nil,
        lastSessionId: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.gitHubRepo = gitHubRepo
        self.lastSessionId = lastSessionId
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, gitHubRepo, lastSessionId, isPinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        gitHubRepo = try container.decodeIfPresent(String.self, forKey: .gitHubRepo)
        lastSessionId = try container.decodeIfPresent(String.self, forKey: .lastSessionId)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    /// Stable sidebar ordering shared by the UI and model tests. Pinned
    /// projects form the first group; both groups are ordered by latest chat
    /// activity, with projects that have no chats ordered by name.
    public static func sortedForSidebar(
        _ projects: [Project],
        latestActivityByProject: [UUID: Date]
    ) -> [Project] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch (latestActivityByProject[lhs.id], latestActivityByProject[rhs.id]) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}
