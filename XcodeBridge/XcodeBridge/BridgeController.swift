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

    enum CLIInstallState: Equatable {
        case unknown
        case notInstalled
        case installed(current: String, latest: String?)
        case outdated(current: String, latest: String)
        case error(String)
    }

    enum State: String {
        case stopped
        case starting
        case running
        case failed
    }

    private(set) var state: State = .stopped
    private(set) var lastMessage: String = "Idle"
    private(set) var cliInstallState: CLIInstallState = .unknown
    private(set) var cliInstallLocation: URL?
    private(set) var runningCLIDescription: String = "Not running"
    private(set) var socketPath: String?
    private(set) var runningCLIPath: String?
    private(set) var logs: [LogEntry] = []

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let installTargetURL = URL(fileURLWithPath: "/usr/local/bin/xcbridge")
    private let maxLogEntries = 500

    init() {
        refreshCLIStatus()
    }

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

    var installActionTitle: String {
        switch cliInstallState {
        case .outdated:
            return "Upgrade CLI..."
        default:
            return "Install CLI..."
        }
    }

    var canInstallAction: Bool {
        switch cliInstallState {
        case .installed(let current, let latest?):
            return current != latest
        case .installed:
            return false
        case .error, .notInstalled, .outdated, .unknown:
            return true
        }
    }

    var cliStatusText: String {
        switch cliInstallState {
        case .unknown:
            return "CLI: Checking..."
        case .notInstalled:
            return "CLI: Not installed"
        case .installed(let current, let latest?):
            return current == latest ? "CLI: \(current) (latest\(locationSuffix()))" : "CLI: \(current)\(locationSuffix())"
        case .installed(let current, nil):
            return "CLI: \(current)\(locationSuffix())"
        case .outdated(let current, let latest):
            return "CLI: \(current) (latest \(latest)\(locationSuffix()))"
        case .error(let message):
            return "CLI: \(message)"
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
        state = .starting
        lastMessage = "Launching bridge..."

        let proc = Process()
        let (execURL, args) = resolveCLI()
        proc.executableURL = execURL
        proc.arguments = args + ["serve"]
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
            runningCLIDescription = describeCLI(execURL: execURL, args: proc.arguments ?? [])
            runningCLIPath = resolveRunningCLIPath(execURL: execURL, args: proc.arguments ?? [])
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
            state = .stopped
            return
        }
        lastMessage = "Stopping bridge..."
        proc.terminate()

        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if proc.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func installOrUpgradeCLI() {
        guard let sourceURL = resolveCLIInstallSource() else {
            lastMessage = "Cannot locate xcbridge to install."
            return
        }

        do {
            let latestVersion = fetchCLIVersion(at: sourceURL)
            let installedVersion = fetchCLIVersion(at: installTargetURL)
            let shouldOverwrite = shouldOverwriteInstall(latest: latestVersion, installed: installedVersion)
            try installCLI(from: sourceURL, to: installTargetURL, reinstall: shouldOverwrite)
            lastMessage = "Installed CLI to \(installTargetURL.path)"
            refreshCLIStatus()
        } catch InstallError.alreadyExists(let path) {
            lastMessage = "CLI already installed at \(path)."
        } catch {
            if isPermissionError(error) {
                lastMessage = "Install failed: permission denied for /usr/local/bin."
            } else {
                lastMessage = "Install failed: \(error.localizedDescription)"
            }
        }
    }

    private func cleanupProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        runningCLIDescription = "Not running"
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

    private func describeCLI(execURL: URL, args: [String]) -> String {
        if execURL.path == "/usr/bin/env", let firstArg = args.first {
            return "env \(firstArg)"
        }
        return execURL.path
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
        let path = runningCLIPath ?? runningCLIDescription
        let command = path
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

    private func resolveRunningCLIPath(execURL: URL, args: [String]) -> String? {
        if execURL.path != "/usr/bin/env" {
            return execURL.path
        }
        guard let firstArg = args.first else { return nil }
        if firstArg.contains("/") {
            return firstArg
        }
        return resolveInPath(command: firstArg)
    }

    private func resolveInPath(command: String) -> String? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        let paths = pathValue.split(separator: ":").map(String.init)
        for dir in paths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func resolveCLI() -> (URL, [String]) {
        if FileManager.default.isExecutableFile(atPath: installTargetURL.path) {
            return (installTargetURL, [])
        }

        if let envPath = ProcessInfo.processInfo.environment["XCODE_BRIDGE_CLI"], !envPath.isEmpty {
            let expanded = expandTilde(envPath)
            let url = URL(fileURLWithPath: expanded)
            return (url, [])
        }

        if let bundleURL = Bundle.main.url(forResource: "xcbridge", withExtension: nil) {
            return (bundleURL, [])
        }

        if let execURL = Bundle.main.executableURL {
            let buildProducts = execURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let candidate = buildProducts.appendingPathComponent("xcbridge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return (candidate, [])
            }
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), ["xcbridge"])
    }

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst())
        }
        return path
    }

    private func locationSuffix() -> String {
        guard let location = cliInstallLocation else { return "" }
        return " @ " + location.deletingLastPathComponent().path
    }

    private func installedCLIURL() -> URL? {
        if FileManager.default.isExecutableFile(atPath: installTargetURL.path) {
            return installTargetURL
        }
        return nil
    }

    func refreshCLIStatus() {
        let sourceURL = resolveCLIInstallSource()
        Task.detached { [weak self] in
            guard let self else { return }
            let latestVersion = sourceURL.flatMap { self.fetchCLIVersion(at: $0) }
            let installedURL = await MainActor.run { self.installedCLIURL() }

            await MainActor.run {
                self.cliInstallLocation = installedURL
            }

            guard let installedURL else {
                await MainActor.run {
                    self.cliInstallState = .notInstalled
                }
                return
            }

            let installedVersion = self.fetchCLIVersion(at: installedURL)
            await MainActor.run {
                if let installedVersion, let latestVersion {
                    if self.isVersion(installedVersion, lessThan: latestVersion) {
                        self.cliInstallState = .outdated(current: installedVersion, latest: latestVersion)
                    } else {
                        self.cliInstallState = .installed(current: installedVersion, latest: latestVersion)
                    }
                } else if let installedVersion {
                    self.cliInstallState = .installed(current: installedVersion, latest: latestVersion)
                } else if let latestVersion {
                    self.cliInstallState = .outdated(current: "unknown", latest: latestVersion)
                } else {
                    self.cliInstallState = .unknown
                }
            }
        }
    }

    nonisolated private func fetchCLIVersion(at url: URL) -> String? {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--version"]

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
        let raw = String(decoding: data, as: UTF8.self)
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    nonisolated private func shouldOverwriteInstall(latest: String?, installed: String?) -> Bool {
        if let latest, let installed {
            return installed != latest
        }
        return true
    }


    private func isVersion(_ lhs: String, lessThan rhs: String) -> Bool {
        let left = parseVersion(lhs)
        let right = parseVersion(rhs)
        return left.lexicographicallyPrecedes(right)
    }

    private func parseVersion(_ version: String) -> [Int] {
        let cleaned = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-")
            .first ?? ""
        let parts = cleaned.split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        return numbers.isEmpty ? [0] : numbers
    }

    private func resolveCLIInstallSource() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["XCODE_BRIDGE_CLI"], !envPath.isEmpty {
            let expanded = expandTilde(envPath)
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }

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

    private func installCLI(from sourceURL: URL, to destinationURL: URL, reinstall: Bool) throws {
        let fileManager = FileManager.default
        let destinationDir = destinationURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if reinstall {
                try fileManager.removeItem(at: destinationURL)
            } else {
                throw InstallError.alreadyExists(destinationURL.path)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }
}

private enum InstallError: Error {
    case alreadyExists(String)
}
