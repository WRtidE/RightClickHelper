import Foundation

enum GuideStep: String, CaseIterable { case menu, copy, create }

struct GuideSession: Codable, Equatable {
    var id = UUID()
    var directoryPath: String
    var startedAt = Date()
}

struct GuideStepResult: Codable {
    var sessionID: UUID
    var time = Date()
}

extension SharedStore {
    func guideSession() -> GuideSession? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("guide-session.json")),
              let session = try? JSONDecoder().decode(GuideSession.self, from: data),
              session.directoryPath.hasPrefix("/"), session.directoryPath != "/" else { return nil }
        return session
    }

    @discardableResult
    func startGuide(in directory: URL) throws -> GuideSession {
        try ActionContext.validateAuthorizationSelection(directory, for: directory)
        let session = GuideSession(directoryPath: directory.path)
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("guide-session.json"), options: .atomic)
        return session
    }

    func guidePassed(_ step: GuideStep, session: GuideSession) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("guide-\(step.rawValue).json")),
              let result = try? JSONDecoder().decode(GuideStepResult.self, from: data) else { return false }
        return result.sessionID == session.id && result.time >= session.startedAt
    }

    func recordGuideStep(_ step: GuideStep, targets: [URL]) {
        guard let session = guideSession(), !targets.isEmpty,
              targets.allSatisfy({ (try? DirectoryBoundary.relativeComponents(of: $0,
                  within: URL(fileURLWithPath: session.directoryPath))) != nil }) else { return }
        // Separate step files prevent a copy/menu event from overwriting a
        // concurrent creation result from the companion process.
        try? JSONEncoder().encode(GuideStepResult(sessionID: session.id))
            .write(to: root.appendingPathComponent("guide-\(step.rawValue).json"), options: .atomic)
    }
}
