import AppKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class BridgeController: @unchecked Sendable {
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let direction: String
        let clientId: Int?
        let message: String
        let raw: String?
    }

    enum State: String {
        case stopped
        case starting
        case running
        case failed
    }

    private(set) var state: State = .stopped
    private(set) var lastMessage: String = "Idle"
    private(set) var socketPath: String?
    private(set) var runningCLIPath: String?
    private(set) var logs: [LogEntry] = []

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stopRequested = false
    private let maxLogEntries = 500

    init() {}

    var isRunning: Bool {
        state == .running || state == .starting
    }

    var statusText: String {
        switch state {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        }
    }

    var statusSymbol: String {
        switch state {
        case .running:
            return "bolt.horizontal.circle.fill"
        case .starting:
            return "bolt.horizontal.circle"
        case .failed:
            return "bolt.trianglebadge.exclamationmark"
        case .stopped:
            return "bolt.slash"
        }
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard process == nil else { return }
        guard let execURL = resolveEmbeddedCLIURL() else {
            state = .failed
            lastMessage = "Embedded xcbridge not found."
            return
        }
        stopRequested = false

        state = .starting
        lastMessage = "Launching bridge..."

        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = ["serve"]
        proc.environment = buildEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [unowned self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self.handleOutput(data)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [unowned self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self.handleOutput(data)
            }
        }

        proc.terminationHandler = { [unowned self] proc in
            Task { @MainActor in
                self.cleanupProcess()
                let status = proc.terminationStatus
                if self.stopRequested {
                    self.stopRequested = false
                    self.state = .stopped
                    self.lastMessage = "Bridge stopped."
                    return
                }
                if self.state != .stopped {
                    self.state = status == 0 ? .stopped : .failed
                }
                if self.lastMessage.isEmpty {
                    self.lastMessage = "Bridge exited (status \(status))."
                }
            }
        }

        do {
            try proc.run()
            process = proc
            stdoutPipe = outPipe
            stderrPipe = errPipe
            runningCLIPath = execURL.path
            state = .running
            lastMessage = "Bridge running."
        } catch {
            cleanupProcess()
            state = .failed
            lastMessage = "Failed to launch bridge: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let proc = process else {
            stopRequested = false
            state = .stopped
            lastMessage = "Bridge stopped."
            return
        }
        stopRequested = true
        lastMessage = "Stopping bridge..."
        proc.terminate()

        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private func cleanupProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        socketPath = nil
        runningCLIPath = nil
    }

    private func handleOutput(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return }
        for lineSub in lines {
            let line = String(lineSub).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("MUXLOG ") {
                let payload = String(line.dropFirst("MUXLOG ".count))
                handleLogPayload(payload)
                continue
            }
            lastMessage = line
            if let range = line.range(of: "serving on ") {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    socketPath = path
                }
            }
        }
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["MCP_XCODE_PID"] == nil, let pid = findXcodePID() {
            env["MCP_XCODE_PID"] = String(pid)
        }
        return env
    }

    private func findXcodePID() -> Int32? {
        let bundleId = "com.apple.dt.Xcode"
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        return apps.first?.processIdentifier
    }

    func copyMCPCommand() {
        guard let command = runningCLIPath ?? resolveEmbeddedCLIURL()?.path else {
            lastMessage = "Embedded xcbridge not found."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        lastMessage = "Copied CLI path."
    }

    func bringAppToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func handleLogPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return
        }

        let event = dict["event"] as? String ?? "event"
        let clientId = (dict["client"] as? NSNumber)?.intValue
        let raw = dict["raw"] as? String
        let direction: String

        switch event {
        case "client_in":
            direction = "client→mux"
        case "client_out":
            direction = "mux→client"
        case "server_in":
            direction = "server→mux"
        case "server_out":
            direction = "mux→server"
        default:
            direction = event
        }

        let message = raw ?? event
        appendLog(LogEntry(timestamp: Date(), direction: direction, clientId: clientId, message: message, raw: raw))
    }

    private func appendLog(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }
    }

    private func resolveEmbeddedCLIURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "xcbridge", withExtension: nil) {
            return bundleURL
        }

        if let execURL = Bundle.main.executableURL {
            let buildProducts = execURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let candidate = buildProducts.appendingPathComponent("xcbridge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
