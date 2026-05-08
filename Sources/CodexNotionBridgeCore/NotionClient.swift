import Foundation

public protocol NotionAPIClient: Sendable {
    func retrieveComment(id: String) async throws -> NotionComment
    func retrievePage(id: String) async throws -> NotionPageContext
    func replyToDiscussion(discussionID: String, markdown: String) async throws
}

public final class LiveNotionClient: NotionAPIClient, @unchecked Sendable {
    private let tokenProvider: @Sendable () throws -> String
    private let notionVersionProvider: @Sendable () -> String
    private let session: URLSession

    public init(
        tokenProvider: @escaping @Sendable () throws -> String,
        notionVersionProvider: @escaping @Sendable () -> String,
        session: URLSession = .shared
    ) {
        self.tokenProvider = tokenProvider
        self.notionVersionProvider = notionVersionProvider
        self.session = session
    }

    public func retrieveComment(id: String) async throws -> NotionComment {
        let json = try await request(path: "/v1/comments/\(id)", method: "GET")
        guard let object = json.objectValue else {
            throw RelayError.notionAPI("Retrieve comment returned non-object JSON.")
        }
        let text = plainText(from: object["rich_text"]?.arrayValue ?? [])
        let author = object["display_name"]?["resolved_name"]?.stringValue
            ?? object["created_by"]?["id"]?.stringValue
            ?? "Unknown author"
        let parent = object["parent"]?["page_id"]?.stringValue ?? object["parent"]?["block_id"]?.stringValue

        return NotionComment(
            id: object["id"]?.stringValue ?? id,
            discussionID: object["discussion_id"]?.stringValue,
            text: text,
            createdTime: object["created_time"]?.stringValue,
            author: author,
            parentID: parent,
            raw: json
        )
    }

    public func retrievePage(id: String) async throws -> NotionPageContext {
        let json = try await request(path: "/v1/pages/\(id)", method: "GET")
        guard let object = json.objectValue else {
            throw RelayError.notionAPI("Retrieve page returned non-object JSON.")
        }
        return NotionPageContext(
            id: object["id"]?.stringValue ?? id,
            title: title(from: object["properties"]?.objectValue) ?? id,
            url: object["url"]?.stringValue,
            raw: json
        )
    }

    public func replyToDiscussion(discussionID: String, markdown: String) async throws {
        let body: [String: JSONValue] = [
            "discussion_id": .string(discussionID),
            "markdown": .string(markdown)
        ]
        _ = try await request(path: "/v1/comments", method: "POST", body: try JSONEncoder.bridge.encode(body))
    }

    private func request(path: String, method: String, body: Data? = nil) async throws -> JSONValue {
        let token = try tokenProvider()
        guard let url = URL(string: "https://api.notion.com\(path)") else {
            throw RelayError.notionAPI("Invalid URL path \(path).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersionProvider(), forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw RelayError.notionAPI(message)
        }
        if data.isEmpty {
            return .object([:])
        }
        return try JSONDecoder.bridge.decode(JSONValue.self, from: data)
    }

    private func plainText(from richText: [JSONValue]) -> String {
        richText.map { part in
            part["plain_text"]?.stringValue ?? part["text"]?["content"]?.stringValue ?? ""
        }.joined()
    }

    private func title(from properties: [String: JSONValue]?) -> String? {
        guard let properties else { return nil }
        for property in properties.values {
            guard property["type"]?.stringValue == "title" else { continue }
            let title = plainText(from: property["title"]?.arrayValue ?? [])
            if !title.isEmpty { return title }
        }
        return nil
    }
}
