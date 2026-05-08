import Foundation
import Network

public final class LocalHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let queue = DispatchQueue(label: "CodexNotionBridge.LocalHTTPServer")
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var isRunning: Bool {
        listener != nil
    }

    public func start(port: UInt16) throws {
        if listener != nil {
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RelayError.configuration("Invalid local HTTP port \(port).")
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self, handler] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let id = UUID()
            let server = self
            let httpConnection = HTTPConnection(connection: connection, handler: handler) { [server] in
                server.queue.async {
                    server.connections[id] = nil
                }
            }
            self.connections[id] = httpConnection
            connection.start(queue: self.queue)
            httpConnection.receive()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: LocalHTTPServer.Handler
    private let onComplete: @Sendable () -> Void
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping LocalHTTPServer.Handler, onComplete: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.handler = handler
        self.onComplete = onComplete
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if let request = HTTPParser.parse(self.buffer) {
                Task {
                    let response = await self.handler(request)
                    self.send(response)
                }
                return
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.receive()
        }
    }

    func cancel() {
        connection.cancel()
        onComplete()
    }

    private func send(_ response: HTTPResponse) {
        let data = HTTPSerializer.serialize(response)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }
}

public enum HTTPParser {
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLengthHeader = headers.first { $0.key.lowercased() == "content-length" }?.value
        let contentLength = contentLengthHeader.flatMap(Int.init) ?? 0
        guard data.count >= bodyStart + contentLength else {
            return nil
        }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])

        return HTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }
}

public enum HTTPSerializer {
    public static func serialize(_ response: HTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"

        var text = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(response.body)
        return data
    }
}
