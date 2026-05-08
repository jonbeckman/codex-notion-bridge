import Foundation

public protocol CodexRunning: Sendable {
    func run(_ input: CodexJobInput) async throws -> CodexRunResult
    func stop(jobID: String)
}

public final class LiveCodexRunner: CodexRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "NotionCodexBridge.LiveCodexRunner")
    private var processes: [String: Process] = [:]

    public init() {}

    public func stop(jobID: String) {
        let process = queue.sync {
            processes[jobID]
        }
        process?.terminate()
    }

    public func run(_ input: CodexJobInput) async throws -> CodexRunResult {
        try await Task.detached(priority: .userInitiated) {
            let job = input.job
            let workspaceURL = URL(fileURLWithPath: job.workspacePath)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

            try input.prompt.write(to: URL(fileURLWithPath: job.promptPath), atomically: true, encoding: .utf8)

            let process = Process()

            var arguments = [
                "exec",
                "--json",
                "--output-last-message",
                job.finalMessagePath,
                "--skip-git-repo-check",
                "--cd",
                job.workspacePath
            ]
            if !input.config.codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments.append(contentsOf: ["--model", input.config.codexModel])
            }
            if !input.config.codexProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments.append(contentsOf: ["--profile", input.config.codexProfile])
            }
            arguments.append("-")
            let launch = ProcessLaunch.executableAndArguments(command: input.config.codexPath, arguments: arguments)
            process.executableURL = launch.0
            process.arguments = launch.1

            let inputPipe = Pipe()
            FileManager.default.createFile(atPath: job.stdoutPath, contents: nil)
            FileManager.default.createFile(atPath: job.stderrPath, contents: nil)
            let stdoutHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: job.stdoutPath))
            let stderrHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: job.stderrPath))
            process.standardInput = inputPipe
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            try process.run()
            self.queue.sync {
                self.processes[job.id] = process
            }

            try inputPipe.fileHandleForWriting.write(contentsOf: Data(input.prompt.utf8))
            try inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()

            self.queue.sync {
                self.processes[job.id] = nil
            }

            try stdoutHandle.close()
            try stderrHandle.close()

            let finalMessage = (try? String(contentsOfFile: job.finalMessagePath, encoding: .utf8))
                ?? (try? String(contentsOfFile: job.stdoutPath, encoding: .utf8))
                ?? ""

            return CodexRunResult(
                exitCode: process.terminationStatus,
                finalMessage: finalMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                stdoutPath: job.stdoutPath,
                stderrPath: job.stderrPath,
                pid: process.processIdentifier
            )
        }.value
    }
}
