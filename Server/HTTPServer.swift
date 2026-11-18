import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}

struct HTTPResponse {
    let status: Int
    let body: Data
    var contentType: String = "application/json"
}

/// A deliberately small HTTP/1.1 server: one request per connection, no
/// chunked encoding, no keep-alive, no TLS. It exists so the orchestration
/// engine can be driven from a terminal over the LAN; anything more would be
/// a framework, and iOS has no need for it.
final class HTTPServer {
    private let port: UInt16
    private let handle: (HTTPRequest) -> HTTPResponse
    private var listener: NWListener?

    init(port: UInt16, handle: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handle = handle
    }

    func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(
                domain: "HiveServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无效端口：\(port)"]
            )
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global())
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            if let request = Self.parse(accumulated) {
                let response = self.handle(request)
                self.send(response, on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receive(connection, buffer: accumulated)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }

        var header = "HTTP/1.1 \(response.status) \(reason)\r\n"
        header += "Content-Type: \(response.contentType); charset=utf-8\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? "0"
            contentLength = Int(value) ?? 0
        }

        let bodyStart = headerRange.upperBound
        let body = data[bodyStart...]
        // Wait for the whole body; a partial JSON body is not parseable and
        // treating it as one would produce confusing 400s under load.
        guard body.count >= contentLength else { return nil }

        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            body: Data(body.prefix(contentLength))
        )
    }
}
