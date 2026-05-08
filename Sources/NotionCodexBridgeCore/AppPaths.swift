import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let configURL: URL
    public let dedupeURL: URL
    public let jobsURL: URL
    public let eventsJSONLURL: URL
    public let jobsDirectory: URL

    public init(root: URL? = nil) {
        let supportRoot = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let base = root ?? supportRoot.appendingPathComponent("NotionCodexBridge", isDirectory: true)

        self.root = base
        self.configURL = base.appendingPathComponent("config.json")
        self.dedupeURL = base.appendingPathComponent("dedupe.json")
        self.jobsURL = base.appendingPathComponent("jobs.json")
        self.eventsJSONLURL = base.appendingPathComponent("events.jsonl")
        self.jobsDirectory = base.appendingPathComponent("jobs", isDirectory: true)
    }

    public func ensure() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
    }

    public func jobDirectory(jobID: String) -> URL {
        jobsDirectory.appendingPathComponent(jobID, isDirectory: true)
    }
}
