import Foundation
import Network

protocol WatchSocketClienting: AnyObject {
    var onMessage: ((BridgeMessage) -> Void)? { get set }
    var onStateChange: ((ConnectionState) -> Void)? { get set }

    func connect(to url: URL, token: String, hello: BridgeMessage)
    func disconnect()
    func send(_ message: BridgeMessage)
}

final class WatchSocketClient: WatchSocketClienting {
    var onMessage: ((BridgeMessage) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private var connection: NWConnection?
    private var handshakeBuffer = Data()
    private var receiveBuffer = Data()
    private var isWebSocketReady = false
    private var isHTTPReady = false
    private var httpTarget: WebSocketTarget?
    private var httpPollTask: Task<Void, Never>?
    private var authorization = BridgeAuthorization(token: "")!
    private let httpClientID = "codex-watch"
    private lazy var probeSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration)
    }()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "dev.codexwatch.network-monitor")
    private let connectionQueue = DispatchQueue(label: "dev.codexwatch.socket")
    private var didStartPathMonitor = false
    private var didRunNetworkProbes = false

    func connect(to url: URL, token: String, hello: BridgeMessage) {
        closeCurrentConnection(notify: false)
        startPathMonitor()
        runNetworkProbes()
        onStateChange?(.connecting)

        guard let authorization = BridgeAuthorization(token: token) else {
            onMessage?(BridgeMessage(type: "error", body: "Invalid bridge token"))
            onStateChange?(.disconnected)
            return
        }
        guard let target = WebSocketTarget(url: url) else {
            onMessage?(BridgeMessage(type: "error", body: "Invalid WebSocket URL"))
            onStateChange?(.disconnected)
            return
        }
        self.authorization = authorization

        print("CodexWatch socket connecting \(url.absoluteString)")
        let connection = NWConnection(host: target.host, port: target.port, using: target.parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            self.handleConnectionState(state, connection: connection, target: target, hello: hello)
        }
        connection.start(queue: connectionQueue)
    }

    func disconnect() {
        closeCurrentConnection(notify: true)
    }

    func send(_ message: BridgeMessage) {
        if isHTTPReady {
            sendHTTP(message)
            return
        }
        guard let connection, isWebSocketReady else { return }
        do {
            let data = try encoder.encode(message)
            guard let string = String(data: data, encoding: .utf8) else { return }
            let frame = makeClientFrame(opcode: 0x1, payload: Data(string.utf8))
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, self.connection === connection else { return }
                if let error {
                    self.handleTransportError(error, connection: connection)
                }
            })
        } catch {
            onMessage?(BridgeMessage(type: "error", body: error.localizedDescription))
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection: NWConnection,
        target: WebSocketTarget,
        hello: BridgeMessage
    ) {
        switch state {
        case .ready:
            sendHandshake(on: connection, target: target, hello: hello)
        case .waiting(let error):
            print("CodexWatch socket waiting \(error.localizedDescription)")
            startHTTPFallback(target: target, hello: hello, reason: error.localizedDescription)
        case .failed(let error):
            startHTTPFallback(target: target, hello: hello, reason: error.localizedDescription)
        case .cancelled:
            if self.connection === connection {
                closeCurrentConnection(notify: true)
            }
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func sendHandshake(on connection: NWConnection, target: WebSocketTarget, hello: BridgeMessage) {
        let key = randomBytes(count: 16).base64EncodedString()
        let request = authorization.webSocketHandshakeRequest(target: target, key: key)

        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.handleTransportError(error, connection: connection)
                return
            }
            self.receiveHandshake(on: connection, hello: hello)
        })
    }

    private func receiveHandshake(on connection: NWConnection, hello: BridgeMessage) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.handleTransportError(error, connection: connection)
                return
            }
            if let data {
                self.handshakeBuffer.append(data)
            }
            if let headerRange = self.handshakeBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let responseData = self.handshakeBuffer.subdata(in: 0..<headerRange.upperBound)
                let response = String(decoding: responseData, as: UTF8.self)
                guard response.contains(" 101 ") else {
                    self.handleTransportError(SocketError.handshakeFailed(response), connection: connection)
                    return
                }

                let remainder = self.handshakeBuffer.subdata(in: headerRange.upperBound..<self.handshakeBuffer.count)
                self.handshakeBuffer.removeAll(keepingCapacity: false)
                self.receiveBuffer.append(remainder)
                self.isWebSocketReady = true
                print("CodexWatch socket connected")
                self.onStateChange?(.connected)
                self.send(hello)
                self.drainIncomingFrames()
                self.receiveFrames(on: connection)
                return
            }
            if isComplete {
                self.handleTransportError(SocketError.closed, connection: connection)
                return
            }
            self.receiveHandshake(on: connection, hello: hello)
        }
    }

    private func receiveFrames(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let error {
                self.handleTransportError(error, connection: connection)
                return
            }
            if let data {
                self.receiveBuffer.append(data)
                self.drainIncomingFrames()
            }
            if isComplete {
                self.handleTransportError(SocketError.closed, connection: connection)
                return
            }
            self.receiveFrames(on: connection)
        }
    }

    private func drainIncomingFrames() {
        while receiveBuffer.count >= 2 {
            let bytes = [UInt8](receiveBuffer)
            let opcode = bytes[0] & 0x0f
            let masked = (bytes[1] & 0x80) != 0
            var length = Int(bytes[1] & 0x7f)
            var offset = 2

            if length == 126 {
                guard bytes.count >= offset + 2 else { return }
                length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
            } else if length == 127 {
                guard bytes.count >= offset + 8 else { return }
                length = bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
                offset += 8
            }

            var maskKey: [UInt8] = []
            if masked {
                guard bytes.count >= offset + 4 else { return }
                maskKey = Array(bytes[offset..<(offset + 4)])
                offset += 4
            }
            guard bytes.count >= offset + length else { return }

            var payload = Array(bytes[offset..<(offset + length)])
            receiveBuffer.removeSubrange(0..<(offset + length))
            if masked {
                for index in payload.indices {
                    payload[index] ^= maskKey[index % 4]
                }
            }

            switch opcode {
            case 0x1:
                decodeTextFrame(Data(payload))
            case 0x8:
                closeCurrentConnection(notify: true)
                return
            case 0x9:
                sendPong(Data(payload))
            default:
                break
            }
        }
    }

    private func decodeTextFrame(_ data: Data) {
        guard let decoded = try? decoder.decode(BridgeMessage.self, from: data) else { return }
        onMessage?(decoded)
    }

    private func sendPong(_ payload: Data) {
        guard let connection, isWebSocketReady else { return }
        connection.send(content: makeClientFrame(opcode: 0xA, payload: payload), completion: .idempotent)
    }

    private func closeCurrentConnection(notify: Bool) {
        connection?.cancel()
        connection = nil
        httpPollTask?.cancel()
        httpPollTask = nil
        isHTTPReady = false
        httpTarget = nil
        isWebSocketReady = false
        handshakeBuffer.removeAll(keepingCapacity: false)
        receiveBuffer.removeAll(keepingCapacity: false)
        if notify {
            onStateChange?(.disconnected)
        }
    }

    private func handleTransportError(_ error: Error, connection: NWConnection) {
        guard self.connection === connection else { return }
        print("CodexWatch socket error \(error.localizedDescription)")
        closeCurrentConnection(notify: false)
        onStateChange?(.disconnected)
        onMessage?(BridgeMessage(type: "error", body: error.localizedDescription))
    }

    private func startHTTPFallback(target: WebSocketTarget, hello: BridgeMessage, reason: String) {
        guard !isHTTPReady else { return }
        let fallbackTarget = target.httpFallbackTarget
        print("CodexWatch http fallback starting \(reason) via \(fallbackTarget.url.absoluteString)")
        connection?.cancel()
        connection = nil
        isWebSocketReady = false
        handshakeBuffer.removeAll(keepingCapacity: false)
        receiveBuffer.removeAll(keepingCapacity: false)
        httpTarget = fallbackTarget
        isHTTPReady = true
        sendHTTP(hello, marksConnected: true)
        startHTTPPollLoop()
    }

    private func sendHTTP(_ message: BridgeMessage, marksConnected: Bool = false) {
        guard let url = httpTarget?.httpURL(endpoint: "message", clientID: httpClientID) else { return }
        do {
            var request = authorization.request(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try encoder.encode(message)
            probeSession.dataTask(with: request) { [weak self] data, response, error in
                guard let self, self.isHTTPReady else { return }
                if let error {
                    self.handleHTTPError(error)
                    return
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.handleHTTPError(SocketError.httpFailed)
                    return
                }
                if marksConnected {
                    print("CodexWatch http fallback connected")
                    self.onStateChange?(.connected)
                }
                if let data {
                    self.decodeHTTPEnvelope(data)
                }
            }.resume()
        } catch {
            handleHTTPError(error)
        }
    }

    private func startHTTPPollLoop() {
        httpPollTask?.cancel()
        httpPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollHTTPOnce()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pollHTTPOnce() async {
        guard isHTTPReady, let url = httpTarget?.httpURL(endpoint: "poll", clientID: httpClientID) else { return }
        do {
            let (data, response) = try await probeSession.data(for: authorization.request(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                handleHTTPError(SocketError.httpFailed)
                return
            }
            decodeHTTPEnvelope(data)
        } catch {
            print("CodexWatch http poll error \(error.localizedDescription)")
        }
    }

    private func decodeHTTPEnvelope(_ data: Data) {
        guard let envelope = try? decoder.decode(HTTPBridgeEnvelope.self, from: data) else { return }
        for message in envelope.messages ?? [] {
            onMessage?(message)
        }
    }

    private func handleHTTPError(_ error: Error) {
        guard isHTTPReady else { return }
        print("CodexWatch http error \(error.localizedDescription)")
        isHTTPReady = false
        httpPollTask?.cancel()
        httpPollTask = nil
        onStateChange?(.disconnected)
        onMessage?(BridgeMessage(type: "error", body: error.localizedDescription))
    }

    private func makeClientFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(0x80 | length))
        } else if length <= UInt16.max {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xff))
            frame.append(UInt8(length & 0xff))
        } else {
            frame.append(0x80 | 127)
            var value = UInt64(length).bigEndian
            withUnsafeBytes(of: &value) { frame.append(contentsOf: $0) }
        }

        let maskKey = randomBytes(count: 4)
        frame.append(maskKey)
        let key = [UInt8](maskKey)
        var maskedPayload = [UInt8](payload)
        for index in maskedPayload.indices {
            maskedPayload[index] ^= key[index % 4]
        }
        frame.append(contentsOf: maskedPayload)
        return frame
    }

    private func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    private func startPathMonitor() {
        guard !didStartPathMonitor else { return }
        didStartPathMonitor = true
        pathMonitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.map { interface in
                "\(interface.name):\(interface.type)"
            }.joined(separator: ",")
            print(
                "CodexWatch network path status=\(path.status) reason=\(path.unsatisfiedReason) interfaces=\(interfaces)"
            )
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func runNetworkProbes() {
        guard !didRunNetworkProbes else { return }
        didRunNetworkProbes = true
        probe(URL(string: "https://captive.apple.com/hotspot-detect.html"))
    }

    private func probe(_ url: URL?) {
        guard let url else { return }
        probeSession.dataTask(with: url) { data, response, error in
            if let error {
                print("CodexWatch probe \(url.absoluteString) error \(error.localizedDescription)")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("CodexWatch probe \(url.absoluteString) status \(statusCode) bytes \(data?.count ?? 0)")
        }.resume()
    }
}

struct BridgeAuthorization {
    let headerValue: String?

    init?(token: String) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsLineBreak = normalizedToken.unicodeScalars.contains {
            $0.value == 0x0D || $0.value == 0x0A
        }
        guard !containsLineBreak else { return nil }
        self.headerValue = normalizedToken.isEmpty ? nil : "Bearer \(normalizedToken)"
    }

    func webSocketHandshakeRequest(target: WebSocketTarget, key: String) -> String {
        var headers = [
            "GET \(target.path) HTTP/1.1",
            "Host: \(target.hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13"
        ]
        if let headerValue {
            headers.append("Authorization: \(headerValue)")
        }
        return "\(headers.joined(separator: "\r\n"))\r\n\r\n"
    }

    func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let headerValue {
            request.setValue(headerValue, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

struct WebSocketTarget {
    let url: URL
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let path: String
    let hostHeader: String
    let usesTLS: Bool

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else { return nil }
        guard let hostString = url.host, !hostString.isEmpty else { return nil }
        let usesTLS = scheme == "wss"
        let portNumber = url.port ?? (usesTLS ? 443 : 80)
        guard let rawPort = UInt16(exactly: portNumber), let port = NWEndpoint.Port(rawValue: rawPort) else { return nil }
        let basePath = url.path.isEmpty ? "/" : url.path
        self.url = url
        self.host = NWEndpoint.Host(hostString)
        self.port = port
        self.path = url.query.map { "\(basePath)?\($0)" } ?? basePath
        self.hostHeader = url.port.map { "\(hostString):\($0)" } ?? hostString
        self.usesTLS = usesTLS
    }

    var parameters: NWParameters {
        usesTLS ? .tls : .tcp
    }

    func httpURL(endpoint: String, clientID: String) -> URL? {
        var components = URLComponents()
        components.scheme = usesTLS ? "https" : "http"
        components.host = url.host
        components.port = url.port
        let basePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/\(endpoint)" : "/\(basePath)/\(endpoint)"
        components.queryItems = [URLQueryItem(name: "client", value: clientID)]
        return components.url
    }

    var httpFallbackTarget: WebSocketTarget {
        self
    }
}

private struct HTTPBridgeEnvelope: Decodable {
    var ok: Bool?
    var messages: [BridgeMessage]?
}

private enum SocketError: LocalizedError {
    case closed
    case httpFailed
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .closed:
            return "Socket closed"
        case .httpFailed:
            return "HTTP bridge request failed"
        case .handshakeFailed(let response):
            return "WebSocket handshake failed: \(response.prefix(80))"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected

    var title: String {
        switch self {
        case .disconnected:
            return "Offline"
        case .connecting:
            return "Linking"
        case .connected:
            return "Linked"
        }
    }

    var symbolName: String {
        switch self {
        case .disconnected:
            return "bolt.horizontal.circle"
        case .connecting:
            return "bolt.horizontal.circle.fill"
        case .connected:
            return "bolt.horizontal.fill"
        }
    }
}
