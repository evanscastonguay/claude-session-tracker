import Foundation
import Network

final class HTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.claude-tracker.httpserver", qos: .userInitiated)

    var onEvent: (@Sendable (HookEvent) -> Void)?

    init(port: UInt16 = 7429) {
        self.port = port
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        listener = try NWListener(using: params)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[HTTPServer] Listening on localhost:\(self.port)")
            case .failed(let error):
                print("[HTTPServer] Failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)

        // Accumulate data until we have the full request
        var accumulated = Data()

        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data = data {
                    accumulated.append(data)
                }

                if isComplete || error != nil {
                    self?.processRequest(accumulated, connection: conn)
                    return
                }

                // Check if we have a complete HTTP request (headers + body)
                if let request = String(data: accumulated, encoding: .utf8),
                   Self.isCompleteHTTPRequest(request) {
                    self?.processRequest(accumulated, connection: conn)
                } else {
                    readMore()
                }
            }
        }

        readMore()
    }

    private static func isCompleteHTTPRequest(_ raw: String) -> Bool {
        guard let headerEnd = raw.range(of: "\r\n\r\n") else { return false }
        let headers = raw[raw.startIndex..<headerEnd.lowerBound]

        // Check Content-Length
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let lengthStr = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0"
                if let contentLength = Int(lengthStr) {
                    let bodyStart = raw[headerEnd.upperBound...]
                    return bodyStart.utf8.count >= contentLength
                }
            }
        }

        // No Content-Length header means request is complete after headers
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let (method, path, body) = Self.parseHTTPRequest(raw)

        var statusCode = 200
        var responseBody = Data("{\"status\":\"ok\"}".utf8)

        if method == "POST" && path == "/events" {
            if let body = body {
                do {
                    let event = try JSONDecoder().decode(HookEvent.self, from: body)
                    onEvent?(event)
                } catch {
                    print("[HTTPServer] JSON decode error: \(error)")
                    statusCode = 400
                    responseBody = Data("{\"error\":\"invalid json\"}".utf8)
                }
            } else {
                statusCode = 400
                responseBody = Data("{\"error\":\"no body\"}".utf8)
            }
        } else if method == "GET" && path == "/health" {
            responseBody = Data("{\"status\":\"ok\",\"port\":\(port)}".utf8)
        } else {
            statusCode = 404
            responseBody = Data("{\"error\":\"not found\"}".utf8)
        }

        let statusText = statusCode == 200 ? "OK" : (statusCode == 400 ? "Bad Request" : "Not Found")
        let httpResponse = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
        var fullResponse = Data(httpResponse.utf8)
        fullResponse.append(responseBody)

        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseHTTPRequest(_ raw: String) -> (String, String, Data?) {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerSection = parts.first ?? ""
        let bodyString = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : nil

        let lines = headerSection.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let tokens = requestLine.split(separator: " ")
        let method = tokens.count > 0 ? String(tokens[0]) : "GET"
        let path = tokens.count > 1 ? String(tokens[1]) : "/"

        return (method, path, bodyString.flatMap { $0.isEmpty ? nil : Data($0.utf8) })
    }
}
