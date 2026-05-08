import Foundation

public actor WebhookProcessor {
    private let configStore: AppConfigStore
    private let secretStore: SecretStoring
    private let eventStore: EventStore
    private let paths: AppPaths
    private let notion: NotionAPIClient
    private let codexRunner: CodexRunning

    public init(
        configStore: AppConfigStore,
        secretStore: SecretStoring,
        eventStore: EventStore,
        paths: AppPaths,
        notion: NotionAPIClient,
        codexRunner: CodexRunning
    ) {
        self.configStore = configStore
        self.secretStore = secretStore
        self.eventStore = eventStore
        self.paths = paths
        self.notion = notion
        self.codexRunner = codexRunner
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/notion/webhook" else {
            if request.method == "GET", request.path == "/health" {
                return .json(200, "OK", ["ok": .bool(true)])
            }
            return .text(404, "Not Found", "Not found")
        }
        guard request.method == "POST" else {
            return .text(405, "Method Not Allowed", "Method not allowed")
        }

        do {
            if let token = verificationToken(from: request.body) {
                try secretStore.set(token, for: .notionWebhookVerificationToken)
                try await eventStore.appendEvent(kind: "verification", detail: "Stored Notion webhook verification token.")
                return .json(200, "OK", ["ok": .bool(true), "verification_token_received": .bool(true)])
            }

            let verificationToken = try secretStore.get(.notionWebhookVerificationToken)
            guard let verificationToken, !verificationToken.isEmpty else {
                throw RelayError.missingSecret(.notionWebhookVerificationToken)
            }
            guard NotionSignatureVerifier.verify(
                signatureHeader: request.header("X-Notion-Signature"),
                body: request.body,
                verificationToken: verificationToken
            ) else {
                throw RelayError.invalidSignature
            }

            let event = try WebhookEvent.parse(request.body)
            try await eventStore.appendEvent(kind: "received", detail: event.type, eventID: event.id, commentID: event.commentID)

            guard event.type == "comment.created" else {
                try await eventStore.appendEvent(kind: "ignored", detail: "Ignored \(event.type).", eventID: event.id, commentID: event.commentID)
                return .json(202, "Accepted", ["ok": .bool(true), "ignored": .string("unsupported_event")])
            }
            guard let commentID = event.commentID else {
                throw RelayError.invalidWebhook("comment.created missing entity.id.")
            }
            if try await eventStore.isDuplicateAndMark(eventID: event.id, commentID: commentID) {
                try await eventStore.appendEvent(kind: "duplicate", detail: "Duplicate event or comment.", eventID: event.id, commentID: commentID)
                return .json(202, "Accepted", ["ok": .bool(true), "duplicate": .bool(true)])
            }

            let config = configStore.load()
            let comment = try await notion.retrieveComment(id: commentID)
            guard TriggerFilter.matchedPrefix(in: comment.text, prefixes: config.triggerPrefixes) != nil else {
                try await eventStore.appendEvent(kind: "ignored", detail: "No trigger prefix.", eventID: event.id, commentID: commentID)
                return .json(202, "Accepted", ["ok": .bool(true), "ignored": .string("no_trigger")])
            }

            let page = await retrievePageContext(eventPageID: event.pageID, fallbackParentID: comment.parentID)
            let job = try createJob(event: event, comment: comment, page: page)
            try await eventStore.addJob(job)
            try await eventStore.appendEvent(kind: "accepted", detail: "Queued Codex job \(job.id).", eventID: event.id, commentID: commentID)

            Task {
                await self.runJob(jobID: job.id)
            }

            return .json(202, "Accepted", ["ok": .bool(true), "job_id": .string(job.id)])
        } catch RelayError.invalidSignature {
            try? await eventStore.appendEvent(kind: "rejected", detail: "Invalid signature.")
            return .text(403, "Forbidden", "Invalid signature")
        } catch {
            try? await eventStore.appendEvent(kind: "failed", detail: error.localizedDescription)
            return .text(500, "Internal Server Error", error.localizedDescription)
        }
    }

    public func runJob(jobID: String) async {
        do {
            guard let job = try await eventStore.updateJob(id: jobID, { job in
                job.status = .running
                job.startedAt = Date()
            }) else {
                return
            }

            let input = CodexJobInput(job: job, prompt: makePrompt(for: job), config: configStore.load())
            let result = try await codexRunner.run(input)
            if result.exitCode == 0 {
                _ = try await eventStore.updateJob(id: jobID, { job in
                    job.status = .completed
                    job.completedAt = Date()
                    job.pid = result.pid
                })
                try await reply(job: job, success: true, message: result.finalMessage)
            } else {
                _ = try await eventStore.updateJob(id: jobID, { job in
                    job.status = .failed
                    job.completedAt = Date()
                    job.pid = result.pid
                    job.errorMessage = "Codex exited with status \(result.exitCode)."
                })
                try await reply(job: job, success: false, message: "Codex exited with status \(result.exitCode). See \(job.stderrPath).")
            }
        } catch {
            _ = try? await eventStore.updateJob(id: jobID, { job in
                job.status = .failed
                job.completedAt = Date()
                job.errorMessage = error.localizedDescription
            })
            if let job = await eventStore.allJobs().first(where: { $0.id == jobID }) {
                try? await reply(job: job, success: false, message: error.localizedDescription)
            }
        }
    }

    public func retryJob(jobID: String) async throws {
        guard (try await eventStore.updateJob(id: jobID, { job in
            job.status = .queued
            job.startedAt = nil
            job.completedAt = nil
            job.pid = nil
            job.errorMessage = nil
        })) != nil else {
            return
        }
        try await eventStore.appendEvent(kind: "retry", detail: "Retrying Codex job \(jobID).")
        Task {
            await self.runJob(jobID: jobID)
        }
    }

    public func stopJob(jobID: String) async throws {
        codexRunner.stop(jobID: jobID)
        _ = try await eventStore.updateJob(id: jobID, { job in
            job.status = .stopped
            job.completedAt = Date()
            job.errorMessage = "Stopped by user."
        })
        try await eventStore.appendEvent(kind: "stopped", detail: "Stopped Codex job \(jobID).")
    }

    private func verificationToken(from body: Data) -> String? {
        guard let root = try? JSONDecoder.bridge.decode(JSONValue.self, from: body) else {
            return nil
        }
        return root["verification_token"]?.stringValue
    }

    private func retrievePageContext(eventPageID: String?, fallbackParentID: String?) async -> NotionPageContext {
        let pageID = eventPageID ?? fallbackParentID ?? "unknown"
        if pageID != "unknown", let page = try? await notion.retrievePage(id: pageID) {
            return page
        }
        return NotionPageContext(id: pageID, title: pageID, url: nil, raw: nil)
    }

    private func createJob(event: WebhookEvent, comment: NotionComment, page: NotionPageContext) throws -> RelayJob {
        try paths.ensure()
        let id = UUID().uuidString
        let jobDirectory = paths.jobDirectory(jobID: id)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

        return RelayJob(
            id: id,
            eventID: event.id,
            commentID: comment.id,
            discussionID: comment.discussionID,
            pageID: page.id,
            pageTitle: page.title,
            pageURL: page.url,
            commentText: comment.text,
            status: .queued,
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil,
            pid: nil,
            workspacePath: jobDirectory.path,
            promptPath: jobDirectory.appendingPathComponent("prompt.md").path,
            stdoutPath: jobDirectory.appendingPathComponent("stdout.jsonl").path,
            stderrPath: jobDirectory.appendingPathComponent("stderr.txt").path,
            finalMessagePath: jobDirectory.appendingPathComponent("final-message.md").path,
            errorMessage: nil
        )
    }

    private func makePrompt(for job: RelayJob) -> String {
        let instruction = TriggerFilter.instructionText(from: job.commentText, prefixes: configStore.load().triggerPrefixes)
        return """
        You are running from Codex Notion Bridge, a local macOS app that handles Notion comment requests.

        Source Notion page:
        - Title: \(job.pageTitle)
        - Page ID: \(job.pageID ?? "unknown")
        - URL: \(job.pageURL ?? "unknown")

        Source comment:
        - Comment ID: \(job.commentID)
        - Discussion ID: \(job.discussionID ?? "unknown")

        User instruction:
        \(instruction)

        Constraints:
        - Do not try to call the Notion API directly; this bridge will write your final response back to the discussion.
        - Keep the final response concise and action-focused.
        - If you need credentials, local repo access, or context that is not available in this workspace, say exactly what is missing.
        """
    }

    private func reply(job: RelayJob, success: Bool, message: String) async throws {
        guard let discussionID = job.discussionID, !discussionID.isEmpty else {
            return
        }
        let status = success ? "completed" : "failed"
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(trimmed.prefix(1800))
        try await notion.replyToDiscussion(
            discussionID: discussionID,
            markdown: "Codex \(status):\n\n\(limited.isEmpty ? "(no final message)" : limited)"
        )
    }
}
