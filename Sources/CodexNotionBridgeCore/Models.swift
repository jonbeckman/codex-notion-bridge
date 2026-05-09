import Foundation

public struct AppSetupState: Codable, Equatable, Sendable {
    public var codexConfigured: Bool
    public var onboardingCompleted: Bool

    public init(codexConfigured: Bool, onboardingCompleted: Bool = false) {
        self.codexConfigured = codexConfigured
        self.onboardingCompleted = onboardingCompleted
    }

    public static let `default` = AppSetupState(codexConfigured: false, onboardingCompleted: false)

    enum CodingKeys: String, CodingKey {
        case codexConfigured
        case onboardingCompleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSetupState.default
        self.codexConfigured = try container.decodeIfPresent(Bool.self, forKey: .codexConfigured) ?? defaults.codexConfigured
        self.onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? defaults.onboardingCompleted
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var localPort: UInt16
    public var codexPath: String
    public var codexModel: String
    public var codexProfile: String
    public var tailscalePath: String
    public var triggerPrefixes: [String]
    public var notionVersion: String
    public var autoStartServer: Bool
    public var setup: AppSetupState

    public init(
        localPort: UInt16,
        codexPath: String,
        codexModel: String,
        codexProfile: String,
        tailscalePath: String,
        triggerPrefixes: [String],
        notionVersion: String,
        autoStartServer: Bool,
        setup: AppSetupState = .default
    ) {
        self.localPort = localPort
        self.codexPath = codexPath
        self.codexModel = codexModel
        self.codexProfile = codexProfile
        self.tailscalePath = tailscalePath
        self.triggerPrefixes = triggerPrefixes
        self.notionVersion = notionVersion
        self.autoStartServer = autoStartServer
        self.setup = setup
    }

    public static let `default` = AppConfig(
        localPort: 7676,
        codexPath: "codex",
        codexModel: "",
        codexProfile: "",
        tailscalePath: "tailscale",
        triggerPrefixes: ["@Codex", "codex:"],
        notionVersion: "2026-03-11",
        autoStartServer: true,
        setup: .default
    )

    enum CodingKeys: String, CodingKey {
        case localPort
        case codexPath
        case codexModel
        case codexProfile
        case tailscalePath
        case triggerPrefixes
        case notionVersion
        case autoStartServer
        case setup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig.default

        self.localPort = try container.decodeIfPresent(UInt16.self, forKey: .localPort) ?? defaults.localPort
        self.codexPath = try container.decodeIfPresent(String.self, forKey: .codexPath) ?? defaults.codexPath
        self.codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel) ?? defaults.codexModel
        self.codexProfile = try container.decodeIfPresent(String.self, forKey: .codexProfile) ?? defaults.codexProfile
        self.tailscalePath = try container.decodeIfPresent(String.self, forKey: .tailscalePath) ?? defaults.tailscalePath
        self.triggerPrefixes = try container.decodeIfPresent([String].self, forKey: .triggerPrefixes) ?? defaults.triggerPrefixes
        self.notionVersion = try container.decodeIfPresent(String.self, forKey: .notionVersion) ?? defaults.notionVersion
        self.autoStartServer = try container.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? defaults.autoStartServer
        self.setup = try container.decodeIfPresent(AppSetupState.self, forKey: .setup) ?? defaults.setup
    }
}

public enum SecretKey: String, CaseIterable, Hashable, Sendable {
    case notionAPIToken
    case notionWebhookVerificationToken
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func text(_ statusCode: Int, _ reason: String, _ text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            reason: reason,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    public static func json(_ statusCode: Int, _ reason: String, _ object: [String: JSONValue]) -> HTTPResponse {
        let body = (try? JSONEncoder.bridge.encode(object)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            reason: reason,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case stopped
}

public struct RelayJob: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var eventID: String
    public var commentID: String
    public var discussionID: String?
    public var pageID: String?
    public var pageTitle: String
    public var pageURL: String?
    public var commentText: String
    public var status: JobStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var pid: Int32?
    public var workspacePath: String
    public var promptPath: String
    public var stdoutPath: String
    public var stderrPath: String
    public var finalMessagePath: String
    public var errorMessage: String?
}

public struct RelayEventRecord: Codable, Sendable {
    public var id: String
    public var eventID: String?
    public var commentID: String?
    public var kind: String
    public var detail: String
    public var createdAt: Date
}

public struct RelaySnapshot: Codable, Equatable, Sendable {
    public var serverRunning: Bool
    public var hasNotionToken: Bool
    public var hasWebhookVerificationToken: Bool
    public var lastEventAt: Date?
    public var totalReceived: Int
    public var totalIgnored: Int
    public var totalFailed: Int
    public var totalCompleted: Int
    public var consumed1h: Int
    public var consumed24h: Int
    public var consumed72h: Int
    public var activeJobs: [RelayJob]

    public init(
        serverRunning: Bool,
        hasNotionToken: Bool,
        hasWebhookVerificationToken: Bool,
        lastEventAt: Date?,
        totalReceived: Int,
        totalIgnored: Int,
        totalFailed: Int,
        totalCompleted: Int,
        consumed1h: Int,
        consumed24h: Int,
        consumed72h: Int,
        activeJobs: [RelayJob]
    ) {
        self.serverRunning = serverRunning
        self.hasNotionToken = hasNotionToken
        self.hasWebhookVerificationToken = hasWebhookVerificationToken
        self.lastEventAt = lastEventAt
        self.totalReceived = totalReceived
        self.totalIgnored = totalIgnored
        self.totalFailed = totalFailed
        self.totalCompleted = totalCompleted
        self.consumed1h = consumed1h
        self.consumed24h = consumed24h
        self.consumed72h = consumed72h
        self.activeJobs = activeJobs
    }
}

public struct WebhookEvent: Equatable, Sendable {
    public var id: String
    public var type: String
    public var commentID: String?
    public var pageID: String?
    public var raw: JSONValue

    public static func parse(_ data: Data) throws -> WebhookEvent {
        let root = try JSONDecoder.bridge.decode(JSONValue.self, from: data)
        guard let object = root.objectValue else {
            throw RelayError.invalidWebhook("Expected a JSON object.")
        }
        guard let id = object["id"]?.stringValue else {
            throw RelayError.invalidWebhook("Missing event id.")
        }
        guard let type = object["type"]?.stringValue else {
            throw RelayError.invalidWebhook("Missing event type.")
        }

        let commentID = object["entity"]?["id"]?.stringValue
        let pageID = object["data"]?["page_id"]?.stringValue
        return WebhookEvent(id: id, type: type, commentID: commentID, pageID: pageID, raw: root)
    }
}

public struct NotionComment: Equatable, Sendable {
    public var id: String
    public var discussionID: String?
    public var text: String
    public var createdTime: String?
    public var author: String
    public var parentID: String?
    public var raw: JSONValue
}

public struct NotionPageContext: Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String?
    public var raw: JSONValue?
}

public struct CodexJobInput: Equatable, Sendable {
    public var job: RelayJob
    public var prompt: String
    public var config: AppConfig
}

public struct CodexRunResult: Equatable, Sendable {
    public var exitCode: Int32
    public var finalMessage: String
    public var stdoutPath: String
    public var stderrPath: String
    public var pid: Int32?
}

public enum RelayError: Error, LocalizedError, Equatable {
    case invalidWebhook(String)
    case missingSecret(SecretKey)
    case invalidSignature
    case unsupportedEvent(String)
    case duplicateEvent
    case processFailed(String)
    case notionAPI(String)
    case configuration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWebhook(let message):
            return "Invalid webhook: \(message)"
        case .missingSecret(let key):
            return "Missing secret: \(key.rawValue)"
        case .invalidSignature:
            return "Invalid Notion webhook signature."
        case .unsupportedEvent(let type):
            return "Unsupported event type: \(type)"
        case .duplicateEvent:
            return "Duplicate event."
        case .processFailed(let message):
            return "Process failed: \(message)"
        case .notionAPI(let message):
            return "Notion API failed: \(message)"
        case .configuration(let message):
            return "Configuration error: \(message)"
        }
    }
}

extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var bridge: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
