import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)

let cliVersion = "0.1.0"

// MARK: - Utilities

func eprint(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + String(path.dropFirst())
    }
    return path
}

func resolvedSocketPath(from argPath: String?) -> String {
    if let env = ProcessInfo.processInfo.environment["XCODE_BRIDGE_SOCKET"], !env.isEmpty {
        return expandTilde(env)
    }
    if let argPath, !argPath.isEmpty {
        return expandTilde(argPath)
    }
    return NSHomeDirectory() + "/.xcode-bridge.sock"
}

func writeAll(fd: Int32, data: Data) -> Bool {
    return data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return true }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written == -1 && errno == EINTR {
                continue
            }
            return false
        }
        return true
    }
}

func readAvailable(fd: Int32, maxBytes: Int = 8192) -> Data? {
    var buffer = [UInt8](repeating: 0, count: maxBytes)
    let count = Darwin.read(fd, &buffer, maxBytes)
    if count > 0 {
        return Data(buffer[0..<count])
    }
    if count == 0 {
        return nil
    }
    if errno == EINTR {
        return Data()
    }
    return nil
}

// MARK: - Message buffer + JSON helpers

enum FrameStyle {
    case line
    case contentLength
}

struct ParsedMessage {
    let data: Data
    let framing: FrameStyle
}

final class MessageBuffer {
    private var buffer = Data()
    private var expectedLength: Int?

    func append(_ data: Data) -> [ParsedMessage] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var messages: [ParsedMessage] = []

        while true {
            if let expected = expectedLength {
                guard buffer.count >= expected else { break }
                let body = buffer.prefix(expected)
                buffer.removeFirst(expected)
                expectedLength = nil
                messages.append(ParsedMessage(data: Data(body), framing: .contentLength))
                continue
            }

            if let headerRange = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
                if let headerString = String(data: headerData, encoding: .utf8),
                   let length = parseContentLength(headerString) {
                    buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                    expectedLength = length
                    continue
                }
            }

            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                messages.append(ParsedMessage(data: line, framing: .line))
                continue
            }

            break
        }

        return messages
    }
}

func parseContentLength(_ header: String) -> Int? {
    let lines = header.split(whereSeparator: \.isNewline)
    for line in lines {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count != 2 { continue }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "content-length" {
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }
    }
    return nil
}

func parseJSONLine(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = obj as? [String: Any] else {
        return nil
    }
    return dict
}

func encodeJSONLine(_ object: Any) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
        return nil
    }
    return data
}

func frameData(_ data: Data, style: FrameStyle) -> Data {
    switch style {
    case .line:
        var framed = data
        framed.append(0x0A)
        return framed
    case .contentLength:
        let header = "Content-Length: \(data.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(data)
        return framed
    }
}

func logMux(_ payload: [String: Any]) {
    guard let data = encodeJSONLine(payload),
          let line = String(data: data, encoding: .utf8) else {
        return
    }
    eprint("MUXLOG \(line)")
}

func logMuxData(event: String, data: Data, prefixLimit: Int = 256) {
    var payload: [String: Any] = ["event": event, "len": data.count]
    let prefix = data.prefix(prefixLimit)
    if let text = String(data: prefix, encoding: .utf8) {
        payload["preview"] = text
    } else {
        payload["previewBase64"] = prefix.base64EncodedString()
    }
    if data.count > prefixLimit {
        payload["truncated"] = true
    }
    logMux(payload)
}

func detectXcodePID() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", "Xcode"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let output = String(decoding: data, as: UTF8.self)
    let pids = output
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard pids.count == 1 else { return nil }
    return pids.first
}

// MARK: - Unix socket helpers

enum SocketError: Error {
    case pathTooLong
    case createFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectFailed(String)
}

func createListeningSocket(path: String) throws -> Int32 {
    let pathCString = path.utf8CString
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    #if os(macOS)
    addr.sun_len = UInt8(MemoryLayout.size(ofValue: addr))
    #endif
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)

    if pathCString.count > sunPathCapacity {
        throw SocketError.pathTooLong
    }

    path.withCString { cString in
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int8.self)
            _ = strncpy(rawPtr, cString, sunPathCapacity)
        }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
        throw SocketError.createFailed(String(cString: strerror(errno)))
    }

    unlink(path)

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        let sockAddrPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
        return Darwin.bind(fd, sockAddrPtr, addrLen)
    }

    if bindResult != 0 {
        close(fd)
        throw SocketError.bindFailed(String(cString: strerror(errno)))
    }

    if listen(fd, SOMAXCONN) != 0 {
        close(fd)
        throw SocketError.listenFailed(String(cString: strerror(errno)))
    }

    chmod(path, S_IRUSR | S_IWUSR)

    return fd
}

func connectToSocket(path: String) throws -> Int32 {
    let pathCString = path.utf8CString
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    #if os(macOS)
    addr.sun_len = UInt8(MemoryLayout.size(ofValue: addr))
    #endif
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)

    if pathCString.count > sunPathCapacity {
        throw SocketError.pathTooLong
    }

    path.withCString { cString in
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int8.self)
            _ = strncpy(rawPtr, cString, sunPathCapacity)
        }
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
        throw SocketError.createFailed(String(cString: strerror(errno)))
    }

    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        let sockAddrPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
        return Darwin.connect(fd, sockAddrPtr, addrLen)
    }

    if connectResult != 0 {
        close(fd)
        throw SocketError.connectFailed(String(cString: strerror(errno)))
    }

    return fd
}

// MARK: - Bridge server (JSON-RPC mux)

private struct ClientConnection {
    let fd: Int32
    let readSource: DispatchSourceRead
}

private struct Pending {
    let clientId: Int
    let localId: Any
    let isInitialize: Bool
    let startedAt: TimeInterval
}

private struct ClientState {
    var handshakeComplete = false
    var framing: FrameStyle = .line
    var buffered: [[String: Any]] = []
    var handshakeStartedAt: TimeInterval?
    var initializeResponseReceived = false
    var initializedNotificationReceived = false
}

final class BridgeServer {
    private let ioQueue = DispatchQueue(label: "xcode-bridge.io")
    private let backendProcess: Process
    private let backendInPipe: Pipe
    private let backendOutPipe: Pipe
    private let backendErrPipe: Pipe
    private let backendInFD: Int32
    private let backendOutFD: Int32
    private let backendErrFD: Int32
    private var backendOutSource: DispatchSourceRead?
    private var backendErrSource: DispatchSourceRead?
    private let backendMessageBuffer = MessageBuffer()

    private var clients: [Int: ClientConnection] = [:]
    private var clientStates: [Int: ClientState] = [:]
    private var pending: [String: Pending] = [:]
    private var initWaiting: [(Int, Any)] = []
    private var cachedInitialize: [String: Any]?
    private var initializing = false
    private var serverInitialized = false
    private var nextRequestId: Int64 = 1
    private var nextClientId: Int = 1
    private let maxPending = 512
    private let handshakeTimeout: TimeInterval = 10
    private let requestTimeout: TimeInterval = 30
    private var timeoutTimer: DispatchSourceTimer?
    private let autoDowngradeProtocolVersion = "2025-06-18"

    init() throws {
        var env = ProcessInfo.processInfo.environment
        var pidSource = "env"
        let currentPid = env["MCP_XCODE_PID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentPid.isEmpty {
            if let detected = detectXcodePID() {
                env["MCP_XCODE_PID"] = detected
                pidSource = "auto"
            } else {
                pidSource = "none"
            }
        }
        logMux([
            "event": "backend_env",
            "xcode_pid": env["MCP_XCODE_PID"] ?? "",
            "xcode_session": env["MCP_XCODE_SESSION_ID"] ?? "",
            "server_framing": "line",
            "xcode_pid_source": pidSource
        ])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["mcpbridge"]
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        logMux(["event": "backend_started", "pid": process.processIdentifier])

        self.backendProcess = process
        self.backendInPipe = stdinPipe
        self.backendOutPipe = stdoutPipe
        self.backendErrPipe = stderrPipe
        self.backendInFD = stdinPipe.fileHandleForWriting.fileDescriptor
        self.backendOutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        self.backendErrFD = stderrPipe.fileHandleForReading.fileDescriptor

        process.terminationHandler = { _ in
            eprint("xcode-bridge: backend exited")
            exit(1)
        }

        startBackendReaders()
        startTimeoutTimer()
    }

    func enqueueClient(_ fd: Int32) {
        ioQueue.async {
            let clientId = self.nextClientId
            self.nextClientId += 1
            let messageBuffer = MessageBuffer()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.ioQueue)

            source.setEventHandler { [weak self] in
                guard let self else { return }
                guard let data = readAvailable(fd: fd) else {
                    self.removeClient(clientId)
                    return
                }
                if data.isEmpty {
                    return
                }
                let messages = messageBuffer.append(data)
                for message in messages {
                    self.handleClientMessage(clientId: clientId, message: message)
                }
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()
            self.clients[clientId] = ClientConnection(fd: fd, readSource: source)
            self.clientStates[clientId] = ClientState(handshakeStartedAt: Date().timeIntervalSince1970)
            logMux(["event": "client_connected", "client": clientId])
        }
    }

    private func startBackendReaders() {
        let outSource = DispatchSource.makeReadSource(fileDescriptor: backendOutFD, queue: ioQueue)
        outSource.setEventHandler { [weak self] in
            guard let self else { return }
            guard let data = readAvailable(fd: self.backendOutFD) else {
                eprint("xcode-bridge: backend stdout closed")
                exit(1)
            }
            if data.isEmpty {
                return
            }
            logMuxData(event: "server_stdout_bytes", data: data)
            let messages = self.backendMessageBuffer.append(data)
            for message in messages {
                self.handleServerMessage(message)
            }
        }
        outSource.resume()
        backendOutSource = outSource

        let errSource = DispatchSource.makeReadSource(fileDescriptor: backendErrFD, queue: ioQueue)
        errSource.setEventHandler {
            guard let data = readAvailable(fd: self.backendErrFD) else {
                return
            }
            if data.isEmpty {
                return
            }
            logMuxData(event: "server_stderr_bytes", data: data)
            _ = writeAll(fd: STDERR_FILENO, data: data)
        }
        errSource.resume()
        backendErrSource = errSource
    }

    private func handleClientMessage(clientId: Int, message: ParsedMessage) {
        guard let msg = parseJSONLine(message.data) else {
            logMux(["event": "client_parse_error", "client": clientId])
            return
        }
        if let raw = String(data: message.data, encoding: .utf8) {
            logMux(["event": "client_in", "client": clientId, "raw": raw])
        }
        if var state = clientStates[clientId] {
            state.framing = message.framing
            clientStates[clientId] = state
        }
        handleClientMessage(clientId: clientId, msg: msg)
    }

    private func handleServerMessage(_ message: ParsedMessage) {
        guard let msg = parseJSONLine(message.data) else {
            logMux(["event": "server_parse_error"])
            return
        }
        if let raw = String(data: message.data, encoding: .utf8) {
            logMux(["event": "server_in", "raw": raw])
        }
        handleServerMessage(msg)
    }

    private func handleClientMessage(clientId: Int, msg: [String: Any]) {
        guard var state = clientStates[clientId] else { return }
        let method = msg["method"] as? String ?? ""
        let idValue = msg["id"]

        if method == "initialize", let localId = idValue {
            state.handshakeComplete = false
            if state.handshakeStartedAt == nil {
                state.handshakeStartedAt = Date().timeIntervalSince1970
            }
            state.initializeResponseReceived = false
            state.initializedNotificationReceived = false
            clientStates[clientId] = state
            handleInitialize(clientId: clientId, localId: localId, msg: msg)
            return
        }

        if method == "notifications/initialized" {
            if !serverInitialized {
                serverInitialized = true
                sendToServer(msg)
            }
            state.initializedNotificationReceived = true
            if state.initializeResponseReceived {
                state.handshakeComplete = true
                flushBuffered(clientId: clientId)
            }
            state.handshakeStartedAt = nil
            clientStates[clientId] = state
            return
        }

        if idValue == nil || idValue is NSNull {
            sendToServer(msg)
            return
        }

        if !state.handshakeComplete {
            state.buffered.append(msg)
            clientStates[clientId] = state
            return
        }

        forwardRequest(clientId: clientId, msg: msg, isInitialize: false)
    }

    private func handleInitialize(clientId: Int, localId: Any, msg: [String: Any]) {
        var adjusted = msg
        if var params = adjusted["params"] as? [String: Any],
           let current = params["protocolVersion"] as? String,
           isProtocolVersion(current, greaterThan: autoDowngradeProtocolVersion) {
            params["protocolVersion"] = autoDowngradeProtocolVersion
            adjusted["params"] = params
            logMux(["event": "protocol_downgrade", "from": current, "to": autoDowngradeProtocolVersion])
        }

        if let cached = cachedInitialize {
            var response = cached
            response["id"] = localId
            sendToClient(clientId: clientId, msg: response)
            if var state = clientStates[clientId] {
                state.initializeResponseReceived = true
                if state.initializedNotificationReceived {
                    state.handshakeComplete = true
                    state.handshakeStartedAt = nil
                    clientStates[clientId] = state
                    flushBuffered(clientId: clientId)
                } else {
                    clientStates[clientId] = state
                }
            }
            return
        }

        if initializing {
            initWaiting.append((clientId, localId))
            return
        }

        initializing = true
        forwardRequest(clientId: clientId, msg: adjusted, isInitialize: true)
        sendSyntheticInitializedIfNeeded()
    }

    private func flushBuffered(clientId: Int) {
        guard var state = clientStates[clientId] else { return }
        let buffered = state.buffered
        state.buffered.removeAll()
        clientStates[clientId] = state
        for msg in buffered {
            forwardRequest(clientId: clientId, msg: msg, isInitialize: false)
        }
    }

    private func forwardRequest(clientId: Int, msg: [String: Any], isInitialize: Bool) {
        if pending.count >= maxPending {
            if let localId = msg["id"] {
                sendToClient(clientId: clientId, msg: errorResponse(id: localId, message: "mux overloaded"))
            }
            return
        }

        let backendId = nextRequestId
        nextRequestId += 1
        let backendKey = String(backendId)
        pending[backendKey] = Pending(
            clientId: clientId,
            localId: msg["id"] as Any,
            isInitialize: isInitialize,
            startedAt: Date().timeIntervalSince1970
        )

        var outbound = msg
        outbound["id"] = backendId
        sendToServer(outbound)
    }

    private func handleServerMessage(_ msg: [String: Any]) {
        let idValue = msg["id"]

        if idValue == nil || idValue is NSNull {
            broadcast(msg)
            return
        }

        let idString: String?
        if let str = idValue as? String {
            idString = str
        } else if let num = idValue as? NSNumber {
            idString = num.stringValue
        } else {
            idString = nil
        }

        guard let idString, let pendingEntry = pending.removeValue(forKey: idString) else {
            return
        }

        if pendingEntry.isInitialize {
            cachedInitialize = msg
            initializing = false

            let waiters = initWaiting
            initWaiting.removeAll()
            for (clientId, localId) in waiters {
                var resp = msg
                resp["id"] = localId
                sendToClient(clientId: clientId, msg: resp)
                if var state = clientStates[clientId] {
                    state.initializeResponseReceived = true
                    if state.initializedNotificationReceived {
                        state.handshakeComplete = true
                        state.handshakeStartedAt = nil
                        clientStates[clientId] = state
                        flushBuffered(clientId: clientId)
                    } else {
                        clientStates[clientId] = state
                    }
                }
            }
        }

        var response = msg
        response["id"] = pendingEntry.localId
        sendToClient(clientId: pendingEntry.clientId, msg: response)
        if pendingEntry.isInitialize, var state = clientStates[pendingEntry.clientId] {
            state.initializeResponseReceived = true
            if state.initializedNotificationReceived {
                state.handshakeComplete = true
                state.handshakeStartedAt = nil
                clientStates[pendingEntry.clientId] = state
                flushBuffered(clientId: pendingEntry.clientId)
            } else {
                clientStates[pendingEntry.clientId] = state
            }
        }
    }

    private func broadcast(_ msg: [String: Any]) {
        for (clientId, _) in clients {
            sendToClient(clientId: clientId, msg: msg)
        }
    }

    private func sendToServer(_ msg: [String: Any]) {
        guard let data = encodeJSONLine(msg) else { return }
        let framed = frameData(data, style: .line)
        _ = writeAll(fd: backendInFD, data: framed)
        logMuxData(event: "server_out_bytes", data: framed)
        if let raw = String(data: data, encoding: .utf8) {
            logMux(["event": "server_out", "raw": raw])
        }
    }

    private func sendSyntheticInitializedIfNeeded() {
        if serverInitialized {
            return
        }
        serverInitialized = true
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ]
        sendToServer(payload)
        logMux(["event": "synthetic_initialized"])
    }

    private func sendToClient(clientId: Int, msg: [String: Any]) {
        guard let client = clients[clientId],
              let data = encodeJSONLine(msg) else {
            return
        }
        let framing = clientStates[clientId]?.framing ?? .line
        let framed = frameData(data, style: framing)
        if !writeAll(fd: client.fd, data: framed) {
            removeClient(clientId)
            return
        }
        if let raw = String(data: data, encoding: .utf8) {
            logMux(["event": "client_out", "client": clientId, "raw": raw])
        }
    }

    private func removeClient(_ clientId: Int) {
        if let client = clients.removeValue(forKey: clientId) {
            client.readSource.cancel()
        }
        clientStates.removeValue(forKey: clientId)
        initWaiting.removeAll { $0.0 == clientId }
        pending = pending.filter { $0.value.clientId != clientId }
        if !pending.values.contains(where: { $0.isInitialize }) {
            initializing = false
        }
        logMux(["event": "client_disconnected", "client": clientId])
    }

    private func errorResponse(id: Any, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32000,
                "message": message
            ]
        ]
    }

    private func isProtocolVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        return protocolVersionValue(lhs) > protocolVersionValue(rhs)
    }

    private func protocolVersionValue(_ value: String) -> Int {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return 0
        }
        return year * 10_000 + month * 100 + day
    }

    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.checkTimeouts()
        }
        timer.resume()
        timeoutTimer = timer
    }

    private func checkTimeouts() {
        let now = Date().timeIntervalSince1970

        var timedOutClients: [Int] = []
        for (clientId, state) in clientStates {
            guard !state.handshakeComplete,
                  let startedAt = state.handshakeStartedAt,
                  now - startedAt > handshakeTimeout else {
                continue
            }
            timedOutClients.append(clientId)
        }

        for clientId in timedOutClients {
            sendToClient(clientId: clientId, msg: errorResponse(id: NSNull(), message: "handshake timeout"))
            logMux(["event": "client_handshake_timeout", "client": clientId])
            removeClient(clientId)
        }

        var expired: [(String, Pending)] = []
        for (key, entry) in pending {
            if now - entry.startedAt > requestTimeout {
                expired.append((key, entry))
            }
        }

        for (key, entry) in expired {
            pending.removeValue(forKey: key)
            sendToClient(clientId: entry.clientId, msg: errorResponse(id: entry.localId, message: "request timeout"))
            logMux(["event": "request_timeout", "client": entry.clientId])
            if entry.isInitialize {
                initializing = false
                cachedInitialize = nil
                let waiters = initWaiting
                initWaiting.removeAll()
                for (clientId, localId) in waiters {
                    sendToClient(clientId: clientId, msg: errorResponse(id: localId, message: "initialize timeout"))
                }
            }
        }
    }
}

// MARK: - Stdio connector

final class StdioConnector {
    private let ioQueue = DispatchQueue(label: "xcode-bridge.connect")
    private let socketFD: Int32
    private var stdinSource: DispatchSourceRead?
    private var socketSource: DispatchSourceRead?

    init(socketFD: Int32) {
        self.socketFD = socketFD
    }

    func start() {
        let stdinFD = STDIN_FILENO
        let stdoutFD = STDOUT_FILENO

        let stdinSource = DispatchSource.makeReadSource(fileDescriptor: stdinFD, queue: ioQueue)
        stdinSource.setEventHandler {
            guard let data = readAvailable(fd: stdinFD) else {
                shutdown(self.socketFD, SHUT_WR)
                return
            }
            if data.isEmpty {
                return
            }
            _ = writeAll(fd: self.socketFD, data: data)
        }
        stdinSource.resume()
        self.stdinSource = stdinSource

        let socketSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: ioQueue)
        socketSource.setEventHandler {
            guard let data = readAvailable(fd: self.socketFD) else {
                exit(0)
            }
            if data.isEmpty {
                return
            }
            _ = writeAll(fd: stdoutFD, data: data)
        }
        socketSource.resume()
        self.socketSource = socketSource

        dispatchMain()
    }
}

// MARK: - CLI

enum Mode {
    case serve
    case connect
    case help
    case version
}

func printHelp() {
    let help = """
    Usage:
      xcode-bridge serve [--socket <path>]
      xcode-bridge connect [--socket <path>]
      xcode-bridge --version
      xcode-bridge --help

    Environment:
      XCODE_BRIDGE_SOCKET  Override the socket path

    Notes:
      - This bridge multiplexes MCP JSON-RPC messages across clients.
      - The bridge is a raw stdio pipe; it does not validate MCP schema.
    """
    print(help)
}

var args = Array(CommandLine.arguments.dropFirst())
var mode: Mode = .connect
var socketArg: String?

if args.contains("--version") || args.contains("-v") {
    mode = .version
}

if let first = args.first, !first.hasPrefix("-") {
    switch first {
    case "serve":
        mode = .serve
        args.removeFirst()
    case "connect":
        mode = .connect
        args.removeFirst()
    case "help":
        mode = .help
        args.removeFirst()
    case "version":
        mode = .version
        args.removeFirst()
    default:
        eprint("xcode-bridge: unknown command \(first)")
        printHelp()
        exit(2)
    }
}

var i = 0
while i < args.count {
    let arg = args[i]
    if arg == "--help" || arg == "-h" {
        mode = .help
        i += 1
        continue
    }
    if arg == "--version" || arg == "-v" {
        mode = .version
        i += 1
        continue
    }
    if arg == "--socket" {
        if i + 1 >= args.count {
            eprint("xcode-bridge: missing value for --socket")
            exit(2)
        }
        socketArg = args[i + 1]
        i += 2
        continue
    }
    if arg.hasPrefix("--socket=") {
        socketArg = String(arg.dropFirst("--socket=".count))
        i += 1
        continue
    }
    eprint("xcode-bridge: unknown argument \(arg)")
    exit(2)
}

switch mode {
case .help:
    printHelp()
    exit(0)
case .version:
    print(cliVersion)
    exit(0)
case .serve:
    let socketPath = resolvedSocketPath(from: socketArg)
    do {
        let listenerFD = try createListeningSocket(path: socketPath)
        let bridge = try BridgeServer()

        DispatchQueue.global().async {
            while true {
                var addr = sockaddr()
                var len: socklen_t = socklen_t(MemoryLayout.size(ofValue: addr))
                let clientFD = Darwin.accept(listenerFD, &addr, &len)
                if clientFD < 0 {
                    continue
                }
                bridge.enqueueClient(clientFD)
            }
        }

        eprint("xcode-bridge: serving on \(socketPath)")
        dispatchMain()
    } catch {
        eprint("xcode-bridge: failed to start server: \(error)")
        exit(1)
    }
case .connect:
    let socketPath = resolvedSocketPath(from: socketArg)
    do {
        let fd = try connectToSocket(path: socketPath)
        let connector = StdioConnector(socketFD: fd)
        connector.start()
    } catch {
        eprint("xcode-bridge: failed to connect: \(error)")
        exit(1)
    }
}
