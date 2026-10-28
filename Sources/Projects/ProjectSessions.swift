import Foundation

/// Which LiveShortly sessions belong to which project.
///
/// The LiveShortly server has no concept of a PocketAI project, so the link is
/// local to this machine — the same arrangement the iPhone app uses, and the
/// same `UserDefaults` key, so a session started on either stays associated on
/// that device.
///
/// ponytail: plain UserDefaults, no pruning. A deleted session leaves a dead
/// id behind, which the view filters out when the session no longer resolves.
enum ProjectSessions {
    private static func key(_ projectId: String) -> String {
        "project.lsSessions.\(projectId)"
    }

    static func ids(for projectId: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(projectId)) ?? []
    }

    static func link(_ sessionId: String, to projectId: String) {
        var current = ids(for: projectId)
        guard !current.contains(sessionId) else { return }
        current.append(sessionId)
        UserDefaults.standard.set(current, forKey: key(projectId))
    }

    static func unlink(_ sessionId: String, from projectId: String) {
        let remaining = ids(for: projectId).filter { $0 != sessionId }
        UserDefaults.standard.set(remaining, forKey: key(projectId))
    }
}
