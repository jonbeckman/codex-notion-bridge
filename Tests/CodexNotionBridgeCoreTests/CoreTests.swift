import Foundation
import XCTest
@testable import CodexNotionBridgeCore

final class CoreTests: XCTestCase {
    func testNotionSignatureMatchesDocumentationSample() {
        let token = "notion_webhook_test_token"
        let body = Data(#"{"verification_token":"notion_webhook_test_token"}"#.utf8)
        let signature = NotionSignatureVerifier.expectedSignature(body: body, verificationToken: token)
        XCTAssertEqual(signature, "sha256=f23df7d97ea58f3b524065333ba991b2a7937ed7799faebe0af90fb124d16fd6")
        XCTAssertTrue(NotionSignatureVerifier.verify(signatureHeader: signature, body: body, verificationToken: token))
        XCTAssertFalse(NotionSignatureVerifier.verify(signatureHeader: signature, body: Data("{}".utf8), verificationToken: token))
    }

    func testTriggerPrefixesAreCaseInsensitiveAndAnchored() {
        XCTAssertEqual(TriggerFilter.matchedPrefix(in: "@Codex do it", prefixes: ["@Codex", "codex:"]), "@Codex")
        XCTAssertEqual(TriggerFilter.matchedPrefix(in: "codex: do it", prefixes: ["@Codex", "codex:"]), "codex:")
        XCTAssertEqual(TriggerFilter.matchedPrefix(in: "CODEX: do it", prefixes: ["@Codex", "codex:"]), "codex:")
        XCTAssertNil(TriggerFilter.matchedPrefix(in: "please @Codex do it", prefixes: ["@Codex", "codex:"]))
        XCTAssertEqual(TriggerFilter.instructionText(from: "codex: do it", prefixes: ["@Codex", "codex:"]), "do it")
    }

    func testCachedSecretStoreReadsBackingOncePerKey() throws {
        let backing = CountingSecretStore(values: [.notionAPIToken: "notion_token"])
        let store = CachedSecretStore(backing: backing)

        XCTAssertEqual(try store.get(.notionAPIToken), "notion_token")
        XCTAssertEqual(try store.get(.notionAPIToken), "notion_token")
        XCTAssertEqual(backing.getCount(for: .notionAPIToken), 1)

        try store.set("updated_token", for: .notionAPIToken)
        XCTAssertEqual(try store.get(.notionAPIToken), "updated_token")
        XCTAssertEqual(backing.getCount(for: .notionAPIToken), 1)

        try store.delete(.notionAPIToken)
        XCTAssertNil(try store.get(.notionAPIToken))
        XCTAssertEqual(backing.getCount(for: .notionAPIToken), 1)
    }

    func testAppConfigDecodesMissingNewFieldsWithDefaults() throws {
        let data = Data("""
        {
          "localPort": 7676,
          "codexPath": "codex",
          "codexModel": "",
          "codexProfile": "",
          "cloudflaredPath": "cloudflared",
          "cloudflareTunnelName": "codex-notion-bridge",
          "publicWebhookHostname": "",
          "triggerPrefixes": ["@Codex", "codex:"],
          "notionVersion": "2026-03-11",
          "autoStartServer": true,
          "autoStartTunnel": false
        }
        """.utf8)

        let config = try JSONDecoder.bridge.decode(AppConfig.self, from: data)

        XCTAssertEqual(config.cloudflareTunnelName, "codex-notion-bridge")
        XCTAssertEqual(config.cloudflareAccountID, "")
    }

    func testCloudflareTunnelRouteParsingUsesFirstHostnameRoute() throws {
        let tunnelsData = Data("""
        [
          {"id": "tunnel-1", "name": "other"},
          {"id": "tunnel-2", "name": "codex-notion-bridge"}
        ]
        """.utf8)
        let routesData = Data("""
        {
          "success": true,
          "result": [
            {"hostname": "first.example.com", "tunnel_id": "tunnel-2", "deleted_at": null},
            {"hostname": "second.example.com", "tunnel_id": "tunnel-2", "deleted_at": null}
          ]
        }
        """.utf8)

        XCTAssertEqual(try CloudflareTunnelRouteResolver.tunnelID(from: tunnelsData, named: "codex-notion-bridge"), "tunnel-2")
        XCTAssertEqual(try CloudflareTunnelRouteResolver.firstHostnameRoute(from: routesData), "first.example.com")
    }

    func testEventStoreDedupesByEventAndComment() async throws {
        let paths = AppPaths(root: temporaryDirectory())
        try paths.ensure()
        let store = EventStore(paths: paths)

        let first = try await store.isDuplicateAndMark(eventID: "evt_1", commentID: "comment_1")
        let duplicateEvent = try await store.isDuplicateAndMark(eventID: "evt_1", commentID: "comment_2")
        let duplicateComment = try await store.isDuplicateAndMark(eventID: "evt_2", commentID: "comment_1")
        let newEvent = try await store.isDuplicateAndMark(eventID: "evt_3", commentID: "comment_3")

        XCTAssertFalse(first)
        XCTAssertTrue(duplicateEvent)
        XCTAssertTrue(duplicateComment)
        XCTAssertFalse(newEvent)
    }

    func testWebhookVerificationStoresToken() async throws {
        let fixture = try makeProcessorFixture()
        let body = Data(#"{"verification_token":"secret_test"}"#.utf8)
        let request = HTTPRequest(method: "POST", path: "/notion/webhook", headers: [:], body: body)

        let response = await fixture.processor.handle(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try fixture.secrets.get(.notionWebhookVerificationToken), "secret_test")
    }

    func testSignedTriggeredCommentCreatesAndRunsJob() async throws {
        let fixture = try makeProcessorFixture()
        try fixture.secrets.set("secret_test", for: .notionWebhookVerificationToken)

        let body = Data("""
        {"id":"evt_1","type":"comment.created","entity":{"type":"comment","id":"comment_1"},"data":{"page_id":"page_1","parent":{"id":"page_1","type":"page"}}}
        """.utf8)
        let signature = NotionSignatureVerifier.expectedSignature(body: body, verificationToken: "secret_test")
        let request = HTTPRequest(
            method: "POST",
            path: "/notion/webhook",
            headers: ["X-Notion-Signature": signature],
            body: body
        )

        let response = await fixture.processor.handle(request)
        try await Task.sleep(for: .milliseconds(100))
        let jobs = await fixture.eventStore.allJobs()

        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.status, .completed)
        XCTAssertEqual(fixture.notion.replies.count, 1)
    }

    func testUnsignedWebhookIsRejected() async throws {
        let fixture = try makeProcessorFixture()
        try fixture.secrets.set("secret_test", for: .notionWebhookVerificationToken)
        let body = Data(#"{"id":"evt_1","type":"comment.created","entity":{"type":"comment","id":"comment_1"},"data":{"page_id":"page_1"}}"#.utf8)
        let request = HTTPRequest(method: "POST", path: "/notion/webhook", headers: [:], body: body)

        let response = await fixture.processor.handle(request)

        XCTAssertEqual(response.statusCode, 403)
    }

    func testNonTriggerCommentIsIgnored() async throws {
        let fixture = try makeProcessorFixture(commentText: "This is just a note.")
        try fixture.secrets.set("secret_test", for: .notionWebhookVerificationToken)
        let body = Data(#"{"id":"evt_1","type":"comment.created","entity":{"type":"comment","id":"comment_1"},"data":{"page_id":"page_1"}}"#.utf8)
        let signature = NotionSignatureVerifier.expectedSignature(body: body, verificationToken: "secret_test")
        let request = HTTPRequest(method: "POST", path: "/notion/webhook", headers: ["X-Notion-Signature": signature], body: body)

        let response = await fixture.processor.handle(request)
        let jobs = await fixture.eventStore.allJobs()

        XCTAssertEqual(response.statusCode, 202)
        XCTAssertTrue(jobs.isEmpty)
    }

    private func makeProcessorFixture(commentText: String = "@Codex summarize this") throws -> ProcessorFixture {
        let paths = AppPaths(root: temporaryDirectory())
        try paths.ensure()
        let configStore = AppConfigStore(url: paths.configURL)
        try configStore.save(.default)
        let secrets = InMemorySecretStore(values: [.notionAPIToken: "notion_token"])
        let eventStore = EventStore(paths: paths)
        let notion = FakeNotionClient(commentText: commentText)
        let runner = FakeCodexRunner()
        let processor = WebhookProcessor(
            configStore: configStore,
            secretStore: secrets,
            eventStore: eventStore,
            paths: paths,
            notion: notion,
            codexRunner: runner
        )
        return ProcessorFixture(
            processor: processor,
            secrets: secrets,
            eventStore: eventStore,
            notion: notion,
            runner: runner
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNotionBridgeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct ProcessorFixture {
    let processor: WebhookProcessor
    let secrets: InMemorySecretStore
    let eventStore: EventStore
    let notion: FakeNotionClient
    let runner: FakeCodexRunner
}

private final class FakeNotionClient: NotionAPIClient, @unchecked Sendable {
    let commentText: String
    private let queue = DispatchQueue(label: "FakeNotionClient")
    private var storedReplies: [(String, String)] = []

    var replies: [(String, String)] {
        queue.sync { storedReplies }
    }

    init(commentText: String) {
        self.commentText = commentText
    }

    func retrieveComment(id: String) async throws -> NotionComment {
        NotionComment(
            id: id,
            discussionID: "discussion_1",
            text: commentText,
            createdTime: "2026-05-08T12:00:00.000Z",
            author: "Test User",
            parentID: "page_1",
            raw: .object([:])
        )
    }

    func retrievePage(id: String) async throws -> NotionPageContext {
        NotionPageContext(id: id, title: "Test Page", url: "https://notion.so/test", raw: .object([:]))
    }

    func replyToDiscussion(discussionID: String, markdown: String) async throws {
        queue.sync {
            storedReplies.append((discussionID, markdown))
        }
    }
}

private final class FakeCodexRunner: CodexRunning, @unchecked Sendable {
    func stop(jobID: String) {}

    func run(_ input: CodexJobInput) async throws -> CodexRunResult {
        try "Final response".write(toFile: input.job.finalMessagePath, atomically: true, encoding: .utf8)
        return CodexRunResult(
            exitCode: 0,
            finalMessage: "Final response",
            stdoutPath: input.job.stdoutPath,
            stderrPath: input.job.stderrPath,
            pid: 123
        )
    }
}

private final class CountingSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String]
    private var getCounts: [SecretKey: Int] = [:]

    init(values: [SecretKey: String]) {
        self.values = values
    }

    func get(_ key: SecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        getCounts[key, default: 0] += 1
        return values[key]
    }

    func set(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func delete(_ key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    func getCount(for key: SecretKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return getCounts[key, default: 0]
    }
}
