import Foundation

public actor EventStore {
    private let paths: AppPaths
    private var seenEventIDs: Set<String>
    private var seenCommentIDs: Set<String>
    private var eventRecords: [RelayEventRecord]
    private var jobs: [RelayJob]

    public init(paths: AppPaths) {
        self.paths = paths
        self.seenEventIDs = []
        self.seenCommentIDs = []
        self.eventRecords = []
        self.jobs = []

        if let data = try? Data(contentsOf: paths.dedupeURL),
           let dedupe = try? JSONDecoder.bridge.decode(DedupeState.self, from: data) {
            self.seenEventIDs = Set(dedupe.eventIDs)
            self.seenCommentIDs = Set(dedupe.commentIDs)
        }

        if let data = try? Data(contentsOf: paths.jobsURL),
           let jobs = try? JSONDecoder.bridge.decode([RelayJob].self, from: data) {
            self.jobs = jobs
        }

        if let data = try? Data(contentsOf: paths.eventsJSONLURL),
           let text = String(data: data, encoding: .utf8) {
            self.eventRecords = text
                .split(separator: "\n")
                .compactMap { line in
                    try? JSONDecoder.bridge.decode(RelayEventRecord.self, from: Data(line.utf8))
                }
        }
    }

    public func isDuplicateAndMark(eventID: String, commentID: String?) throws -> Bool {
        if seenEventIDs.contains(eventID) {
            return true
        }
        if let commentID, seenCommentIDs.contains(commentID) {
            return true
        }
        seenEventIDs.insert(eventID)
        if let commentID {
            seenCommentIDs.insert(commentID)
        }
        try saveDedupe()
        return false
    }

    public func appendEvent(kind: String, detail: String, eventID: String? = nil, commentID: String? = nil) throws {
        let record = RelayEventRecord(
            id: UUID().uuidString,
            eventID: eventID,
            commentID: commentID,
            kind: kind,
            detail: detail,
            createdAt: Date()
        )
        eventRecords.append(record)
        try appendJSONL(record, to: paths.eventsJSONLURL)
    }

    public func addJob(_ job: RelayJob) throws {
        jobs.insert(job, at: 0)
        try saveJobs()
    }

    public func updateJob(id: String, _ update: (inout RelayJob) -> Void) throws -> RelayJob? {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        update(&jobs[index])
        try saveJobs()
        return jobs[index]
    }

    public func allJobs() -> [RelayJob] {
        jobs
    }

    public func snapshot(
        serverRunning: Bool,
        tunnelRunning: Bool,
        hasNotionToken: Bool,
        hasWebhookVerificationToken: Bool,
        hasCloudflareTunnelToken: Bool
    ) -> RelaySnapshot {
        let now = Date()
        let active = jobs
            .filter { $0.status == .queued || $0.status == .running || $0.status == .failed }
            .prefix(20)
            .map { $0 }

        return RelaySnapshot(
            serverRunning: serverRunning,
            tunnelRunning: tunnelRunning,
            hasNotionToken: hasNotionToken,
            hasWebhookVerificationToken: hasWebhookVerificationToken,
            hasCloudflareTunnelToken: hasCloudflareTunnelToken,
            lastEventAt: eventRecords.map(\.createdAt).max(),
            totalReceived: eventRecords.filter { $0.kind == "received" }.count,
            totalIgnored: eventRecords.filter { $0.kind == "ignored" || $0.kind == "duplicate" }.count,
            totalFailed: jobs.filter { $0.status == .failed }.count,
            totalCompleted: jobs.filter { $0.status == .completed }.count,
            consumed1h: consumedJobs(since: now.addingTimeInterval(-3600)),
            consumed24h: consumedJobs(since: now.addingTimeInterval(-86400)),
            consumed72h: consumedJobs(since: now.addingTimeInterval(-259_200)),
            activeJobs: active
        )
    }

    private func consumedJobs(since date: Date) -> Int {
        jobs.filter { job in
            job.createdAt >= date && (job.status == .running || job.status == .completed || job.status == .failed)
        }.count
    }

    private func saveDedupe() throws {
        try paths.ensure()
        let state = DedupeState(eventIDs: Array(seenEventIDs).sorted(), commentIDs: Array(seenCommentIDs).sorted())
        let data = try JSONEncoder.bridge.encode(state)
        try data.write(to: paths.dedupeURL, options: [.atomic])
    }

    private func saveJobs() throws {
        try paths.ensure()
        let data = try JSONEncoder.bridge.encode(jobs)
        try data.write(to: paths.jobsURL, options: [.atomic])
    }

    private func appendJSONL<T: Encodable>(_ value: T, to url: URL) throws {
        try paths.ensure()
        let data = try JSONEncoder.bridge.encode(value)
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: url.path) {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
    }
}

private struct DedupeState: Codable {
    var eventIDs: [String]
    var commentIDs: [String]
}
