import Foundation
import Network

struct ChatGPTCallback: Equatable, Sendable {
    static let path = "/auth/callback"

    let code: String
    let clientID: String?

    static func parse(_ request: Data, port: UInt16, state: String) throws -> Self? {
        guard let header = String(data: request, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let hosts = lines.dropFirst().compactMap { line -> String? in
            let header = line.split(separator: ":", maxSplits: 1)
            guard header.count == 2, header[0].lowercased() == "host" else { return nil }
            return header[1].trimmingCharacters(in: .whitespaces)
        }
        guard requestLine.count == 3, requestLine[0] == "GET",
              requestLine[2] == "HTTP/1.1", hosts == ["127.0.0.1:\(port)"],
              requestLine[1].hasPrefix(path + "?"),
              let url = URLComponents(string: "http://127.0.0.1:\(port)" + requestLine[1]),
              url.percentEncodedPath == path, url.fragment == nil
        else { return nil }

        var fields: [String: String] = [:]
        for item in url.queryItems ?? [] where ["state", "code", "client_id", "error", "error_description"].contains(item.name) {
            guard fields[item.name] == nil, let value = item.value else { return nil }
            fields[item.name] = value
        }
        guard fields["state"] == state else { return nil }
        if let error = fields["error"] {
            throw ChatGPTFailure.remote(code: error, detail: fields["error_description"],
                                        secrets: [state, fields["code"] ?? ""])
        }
        guard let code = fields["code"], !code.isEmpty else { throw ChatGPTFailure(kind: .loopback) }
        return Self(code: code, clientID: fields["client_id"])
    }

    func issuedClientID(for requested: String) throws -> String {
        if requested != ChatGPTEndpoints.dynamicClient {
            guard clientID == nil || clientID == requested else { throw ChatGPTFailure(kind: .accountMismatch) }
            return requested
        }
        guard let clientID, !clientID.isEmpty, clientID != ChatGPTEndpoints.dynamicClient else {
            throw ChatGPTFailure(kind: .invalidClient)
        }
        return clientID
    }
}

@MainActor
final class ChatGPTLoopback {
    enum Event: Sendable {
        case ready(UInt16)
        case callback(ChatGPTCallback)
    }

    private static let headerEnd = Data([13, 10, 13, 10])
    private let listener: NWListener
    private let state: String
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    let events: AsyncThrowingStream<Event, Error>
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private var acceptedCallback = false

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do { listener = try NWListener(using: parameters) }
        catch { throw ChatGPTFailure(kind: .loopback) }
        (events, continuation) = AsyncThrowingStream.makeStream()
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { self.continuation.yield(.ready(port.rawValue)) }
                    else { self.stop(with: ChatGPTFailure(kind: .loopback)) }
                case .failed, .waiting:
                    self.stop(with: ChatGPTFailure(kind: .loopback))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                if let self { self.accept(connection) } else { connection.cancel() }
            }
        }
        listener.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) }
            catch { return }
            self?.stop(with: ChatGPTFailure(kind: .timeout))
        }
    }

    func stop(with error: Error? = nil) {
        timeout?.cancel()
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        continuation.finish(throwing: error)
    }

    private func accept(_ connection: NWConnection) {
        guard !acceptedCallback, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, soFar: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let connection, connections[id] === connection else { return }
            close(connection)
        }
    }

    private func receive(_ connection: NWConnection, soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
                var header = soFar
                if let data { header.append(data) }
                if header.count <= 16_384, let end = header.range(of: Self.headerEnd) {
                    self.handle(Data(header[..<end.lowerBound]), on: connection)
                } else if ended || error != nil || header.count >= 16_384 {
                    self.close(connection)
                } else {
                    self.receive(connection, soFar: header)
                }
            }
        }
    }

    private func handle(_ header: Data, on connection: NWConnection) {
        guard !acceptedCallback, let port = listener.port else { close(connection); return }
        let result: Result<ChatGPTCallback, Error>
        do {
            guard let callback = try ChatGPTCallback.parse(header, port: port.rawValue, state: state) else {
                reply(on: connection, status: "400 Bad Request", text: "This is not an active NotSoBoringNotch sign-in.")
                return
            }
            result = .success(callback)
        } catch {
            result = .failure(error)
        }
        acceptedCallback = true
        listener.cancel()
        // Complete the HTTP reply before yielding so normal cleanup does not close the browser's connection.
        reply(on: connection, status: "200 OK", text: "Return to NotSoBoringNotch to finish signing in.") { [weak self] in
            guard let self else { return }
            switch result {
            case .success(let callback):
                continuation.yield(.callback(callback))
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    private func reply(on connection: NWConnection, status: String, text: String, then: (@MainActor @Sendable () -> Void)? = nil) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(text.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n" +
            "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n" + text
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak connection] _ in
            MainActor.assumeIsolated {
                if let connection { self?.close(connection) }
                then?()
            }
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }
}
