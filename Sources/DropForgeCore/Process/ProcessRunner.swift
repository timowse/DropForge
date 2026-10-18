import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String

    public init(exitCode: Int32, stdout: Data, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ProcessError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case failed(tool: String, code: Int32, detail: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let tool): "Could not start \(tool)."
        case .failed(let tool, let code, let detail):
            detail.isEmpty ? "\(tool) stopped with error \(code)." : "\(tool) reported: \(detail)"
        case .cancelled: "Cancelled."
        }
    }
}

/// A command to run. Arguments are passed as an array: no shell is involved, so file names never need quoting.
public struct Command: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]?
    public var currentDirectory: URL?

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil, currentDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    public var toolName: String { executable.lastPathComponent }
}

public protocol ProcessRunning: Sendable {
    /// Runs to completion. Cancelling the task terminates the child process. `onLine` receives stdout lines.
    func run(_ command: Command, onLine: (@Sendable (String) -> Void)?) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ command: Command) async throws -> ProcessResult {
        try await run(command, onLine: nil)
    }

    /// Runs and throws `ProcessError.failed` on a non-zero exit.
    @discardableResult
    public func runChecked(_ command: Command, onLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let result = try await run(command, onLine: onLine)
        guard result.exitCode == 0 else {
            throw ProcessError.failed(tool: command.toolName, code: result.exitCode,
                                      detail: ErrorText.lastMeaningfulLine(result.stderr))
        }
        return result
    }
}

public enum ErrorText {
    /// Picks the last informative stderr line for user-facing messages.
    public static func lastMeaningfulLine(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let useful = lines.filter { line in
            !line.isEmpty && !line.hasPrefix("frame=") && !line.hasPrefix("size=") && !line.hasPrefix("[out#")
                && !line.lowercased().hasPrefix("conversion failed")
        }
        let line = useful.last ?? lines.last ?? ""
        return String(line.prefix(300))
    }
}

/// Real implementation backed by `Foundation.Process`.
public struct SystemProcessRunner: ProcessRunning {
    /// How long to wait after SIGTERM before SIGKILL.
    public var killGrace: Duration

    public init(killGrace: Duration = .seconds(2)) {
        self.killGrace = killGrace
    }

    public func run(_ command: Command, onLine: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
        try Task.checkCancellation()
        let box = ProcessBox()
        let grace = killGrace
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                box.continuation = continuation
                let process = Process()
                process.executableURL = command.executable
                process.arguments = command.arguments
                if let env = command.environment {
                    process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
                }
                if let dir = command.currentDirectory { process.currentDirectoryURL = dir }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice

                out.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        box.reachedEOF(stdout: true, onLine: onLine)
                    } else {
                        box.appendStdout(data, onLine: onLine)
                    }
                }
                err.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        box.reachedEOF(stdout: false, onLine: onLine)
                    } else {
                        box.appendStderr(data)
                    }
                }
                process.terminationHandler = { p in
                    box.terminated(status: p.terminationStatus, onLine: onLine)
                    // A grandchild may keep the pipes open; do not wait for it beyond a short drain period.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        box.finish(onLine: onLine)
                    }
                }
                do {
                    try process.run()
                    box.setProcess(process)
                } catch {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    box.fail(ProcessError.launchFailed(command.toolName))
                }
            }
        } onCancel: {
            box.cancel(grace: grace)
        }
    }
}

/// Thread-safe state shared between the process callbacks and the cancellation handler.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var continuation: CheckedContinuation<ProcessResult, Error>?
    private var exitStatus: Int32?
    private var stdoutEOF = false
    private var stderrEOF = false
    private var resumed = false

    func reachedEOF(stdout: Bool, onLine: (@Sendable (String) -> Void)?) {
        lock.withLock { if stdout { stdoutEOF = true } else { stderrEOF = true } }
        finishIfReady(onLine: onLine)
    }

    func terminated(status: Int32, onLine: (@Sendable (String) -> Void)?) {
        lock.withLock { exitStatus = status }
        finishIfReady(onLine: onLine)
    }

    private func finishIfReady(onLine: (@Sendable (String) -> Void)?) {
        let ready = lock.withLock { exitStatus != nil && stdoutEOF && stderrEOF }
        if ready { finish(onLine: onLine) }
    }

    /// Resumes exactly once: after exit and EOF, or after exit plus the drain timeout.
    func finish(onLine: (@Sendable (String) -> Void)?) {
        let action: (CheckedContinuation<ProcessResult, Error>, Result<ProcessResult, Error>)? = lock.withLock {
            guard !resumed, let status = exitStatus, let c = continuation else { return nil }
            resumed = true
            continuation = nil
            if cancelled { return (c, .failure(ProcessError.cancelled)) }
            return (c, .success(ProcessResult(exitCode: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))))
        }
        guard let (c, result) = action else { return }
        flushLine(onLine: onLine)
        switch result {
        case .success(let r):
            // Include a trailing partial line that arrived just before EOF.
            c.resume(returning: r)
        case .failure(let e):
            c.resume(throwing: e)
        }
    }

    func fail(_ error: Error) {
        let c: CheckedContinuation<ProcessResult, Error>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(throwing: error)
    }
    private var stdout = Data()
    private var stderr = Data()
    private var lineBuffer = Data()
    static let stderrLimit = 64 * 1024
    static let stdoutLimit = 64 * 1024 * 1024

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func setProcess(_ p: Process) {
        let cancelNow: Bool = lock.withLock {
            process = p
            return cancelled
        }
        if cancelNow { p.terminate() }
    }

    func cancel(grace: Duration) {
        let p: Process? = lock.withLock {
            cancelled = true
            return process
        }
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        Task.detached {
            try? await Task.sleep(for: grace)
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    func appendStdout(_ data: Data, onLine: (@Sendable (String) -> Void)?) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            if stdout.count < Self.stdoutLimit { stdout.append(data) }
            guard onLine != nil else { return }
            lineBuffer.append(data)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer[lineBuffer.startIndex..<nl]
                lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\r")))
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            }
        }
        if let onLine { lines.forEach(onLine) }
    }

    func flushLine(onLine: (@Sendable (String) -> Void)?) {
        let rest: String? = lock.withLock {
            guard !lineBuffer.isEmpty else { return nil }
            defer { lineBuffer.removeAll() }
            return String(decoding: lineBuffer, as: UTF8.self)
        }
        if let rest, let onLine { onLine(rest) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            stderr.append(data)
            if stderr.count > Self.stderrLimit { stderr = stderr.suffix(Self.stderrLimit) }
        }
    }

    func result(exitCode: Int32) -> ProcessResult {
        lock.withLock { ProcessResult(exitCode: exitCode, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self)) }
    }
}
