//
//  ClaudeCodeCLI.swift
//  leanring-buddy
//
//  Claude backend that shells out to the locally installed Claude Code CLI
//  (`claude -p`) instead of calling the Anthropic API through a proxy. The
//  CLI is authenticated with the user's own Claude subscription, so no API
//  key is needed. Screenshots are passed inline as base64 image blocks via
//  `--input-format stream-json`, and text is streamed back via
//  `--output-format stream-json --include-partial-messages`.
//
//  Reliability:
//  - A spare `claude` process is started ahead of time (ClaudeCodeProcessPool),
//    at low priority and only while YoClicky is idle, so a request doesn't pay
//    the CLI's startup cost. Each request still runs in
//    its own one-shot process, so earlier screenshots never pile up in context.
//  - A request fails with `.timedOut` if the CLI produces no output for 60s.
//  - Transient failures (timeout, crash, overload) are retried once, as long as
//    no text has been streamed to the user yet.
//  - Errors are classified (not installed / not logged in / usage limit) so the
//    UI can say what actually went wrong.
//

import Foundation

// MARK: - Errors

enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case notLoggedIn(details: String)
    case usageLimitReached(details: String)
    case timedOut(seconds: Int)
    case failed(details: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code isn't installed. Install it, then run `claude` in Terminal once to log in."
        case .notLoggedIn(let details):
            return "Claude Code isn't logged in. Run `claude` in Terminal and log in with your Claude account. (\(details))"
        case .usageLimitReached(let details):
            return "Your Claude usage limit is reached. \(details)"
        case .timedOut(let seconds):
            return "Claude Code didn't respond for \(seconds) seconds."
        case .failed(let details):
            return "Claude Code error: \(details)"
        }
    }

    /// Short version read aloud by text-to-speech.
    var spokenDescription: String {
        switch self {
        case .notInstalled:
            return "Claude Code isn't installed on this Mac."
        case .notLoggedIn:
            return "Claude Code isn't logged in. Run claude in Terminal and log in."
        case .usageLimitReached:
            return "You've hit your Claude usage limit. Try again later."
        case .timedOut:
            return "Claude took too long to answer. Try again."
        case .failed:
            return "Something went wrong talking to Claude. Check the logs in settings."
        }
    }

    /// Worth one automatic retry.
    var isRetryable: Bool {
        switch self {
        case .timedOut, .failed: return true
        case .notInstalled, .notLoggedIn, .usageLimitReached: return false
        }
    }

    /// Maps a CLI error message to the most specific case.
    static func classify(_ message: String) -> ClaudeCodeError {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedMessage = trimmedMessage.lowercased()
        let loginMarkers = ["not logged in", "please run /login", "log in", "login", "invalid api key",
                            "authentication", "unauthorized", "oauth", "401"]
        let usageLimitMarkers = ["usage limit", "limit reached", "rate limit", "rate_limit", "429",
                                 "hour limit", "weekly limit", "limit will reset", "resets at"]
        if usageLimitMarkers.contains(where: lowercasedMessage.contains) {
            return .usageLimitReached(details: trimmedMessage)
        }
        if loginMarkers.contains(where: lowercasedMessage.contains) {
            return .notLoggedIn(details: trimmedMessage)
        }
        return .failed(details: trimmedMessage.isEmpty ? "no details" : trimmedMessage)
    }
}

// MARK: - Process launching and the warm spare

/// One `claude -p` process waiting for (or handling) a single request.
final class ClaudeCodeProcess {
    let process: Process
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let configurationKey: String
    let launchedAt = Date()

    /// - Parameter isSpare: spares start at lower CPU priority so their startup
    ///   never competes with speech playback or animations.
    init(executablePath: String, model: String, systemPrompt: String, isSpare: Bool = false) throws {
        configurationKey = Self.configurationKey(model: model, systemPrompt: systemPrompt)

        process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--system-prompt", systemPrompt,
            // Pure chat: no tools, no MCP servers, no user/project settings or
            // hooks, and don't save these sessions to disk.
            "--tools", "",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--no-session-persistence"
        ]
        // Run from a neutral directory so no project CLAUDE.md is picked up.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        // Force subscription auth: an API key in the environment would take precedence.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(homeDirectory)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.qualityOfService = isSpare ? .utility : .userInitiated
        try process.run()
    }

    static func configurationKey(model: String, systemPrompt: String) -> String {
        "\(model)\n\(systemPrompt)"
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// Keeps one pre-started `claude` process ready for the next request.
final class ClaudeCodeProcessPool {
    static let shared = ClaudeCodeProcessPool()

    /// Spares older than this are replaced, in case the CLI's state went stale.
    private static let maxSpareAge: TimeInterval = 15 * 60

    private let lock = NSLock()
    private var spareProcess: ClaudeCodeProcess?

    /// Returns the waiting spare if it matches this model + prompt, otherwise
    /// launches a fresh process. The caller refills the spare with `prewarm`
    /// once it's idle (starting one mid-answer made speech stutter).
    func takeProcess(executablePath: String, model: String, systemPrompt: String) throws -> ClaudeCodeProcess {
        let wantedKey = ClaudeCodeProcess.configurationKey(model: model, systemPrompt: systemPrompt)

        lock.lock()
        let candidate = spareProcess
        spareProcess = nil
        lock.unlock()

        let processForRequest: ClaudeCodeProcess
        if let candidate,
           candidate.configurationKey == wantedKey,
           candidate.process.isRunning,
           Date().timeIntervalSince(candidate.launchedAt) < Self.maxSpareAge {
            print("⚡️ Claude Code: using pre-started process")
            processForRequest = candidate
        } else {
            candidate?.terminate()
            processForRequest = try ClaudeCodeProcess(executablePath: executablePath, model: model, systemPrompt: systemPrompt)
        }

        return processForRequest
    }

    /// Starts a spare process in the background, replacing any existing one.
    func prewarm(executablePath: String, model: String, systemPrompt: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let newSpare = try? ClaudeCodeProcess(executablePath: executablePath, model: model, systemPrompt: systemPrompt, isSpare: true)
            self.lock.lock()
            let replacedSpare = self.spareProcess
            self.spareProcess = newSpare
            self.lock.unlock()
            replacedSpare?.terminate()
        }
    }

    func shutdown() {
        lock.lock()
        let spareToStop = spareProcess
        spareProcess = nil
        lock.unlock()
        spareToStop?.terminate()
    }
}

// MARK: - Client

/// Answers a screenshot + question through the Claude Code CLI (see AIProviderClient).
class ClaudeCodeCLI {
    var model: String
    /// Whether to take requests from (and refill) the shared warm process pool.
    /// Off for one-off calls like the connection test.
    var usesWarmProcessPool = true

    /// A request fails if the CLI produces no output for this long.
    static let inactivityTimeoutSeconds = 60

    init(model: String = "sonnet") {
        self.model = model
    }

    /// Maps the app's stored model IDs (e.g. "claude-sonnet-4-6") to CLI aliases
    /// so the CLI always uses the latest model of that family.
    var cliModelAlias: String {
        let lowercasedModel = model.lowercased()
        if lowercasedModel.contains("opus") { return "opus" }
        if lowercasedModel.contains("haiku") { return "haiku" }
        return "sonnet"
    }

    /// Finds the `claude` binary. GUI apps don't inherit the shell PATH, so we
    /// check the usual install locations. Override with the `claudeCLIPath` user default.
    static func locateClaudeExecutable() -> String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        var candidatePaths: [String] = []
        if let overridePath = UserDefaults.standard.string(forKey: "claudeCLIPath") {
            candidatePaths.append(overridePath)
        }
        candidatePaths += [
            "\(homeDirectory)/.local/bin/claude",
            "\(homeDirectory)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts a spare process for this model + prompt so the next request is fast.
    func prewarm(systemPrompt: String) {
        guard let claudeExecutablePath = Self.locateClaudeExecutable() else { return }
        ClaudeCodeProcessPool.shared.prewarm(
            executablePath: claudeExecutablePath,
            model: cliModelAlias,
            systemPrompt: systemPrompt
        )
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.count >= 4 && [UInt8](imageData.prefix(4)) == pngSignature {
            return "image/png"
        }
        return "image/jpeg"
    }

    /// Send a vision request to Claude through the CLI with streaming.
    /// Calls `onTextChunk` with the accumulated text each time new text arrives.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let claudeExecutablePath = Self.locateClaudeExecutable() else {
            throw ClaudeCodeError.notInstalled
        }

        let inputData = try makeInputData(images: images, conversationHistory: conversationHistory, userPrompt: userPrompt)
        let payloadMB = Double(inputData.count) / 1_048_576.0
        print("🌐 Claude Code CLI request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model \(cliModelAlias)")

        var attemptNumber = 1
        while true {
            let progress = ResponseProgress()
            do {
                let claudeProcess: ClaudeCodeProcess
                if usesWarmProcessPool {
                    claudeProcess = try ClaudeCodeProcessPool.shared.takeProcess(
                        executablePath: claudeExecutablePath,
                        model: cliModelAlias,
                        systemPrompt: systemPrompt
                    )
                } else {
                    claudeProcess = try ClaudeCodeProcess(
                        executablePath: claudeExecutablePath,
                        model: cliModelAlias,
                        systemPrompt: systemPrompt
                    )
                }

                // The task group inside runRequest always finishes before it returns,
                // so the callback never actually outlives this call.
                let responseText = try await withoutActuallyEscaping(onTextChunk) { escapableOnTextChunk in
                    try await runRequest(
                        on: claudeProcess,
                        inputData: inputData,
                        progress: progress,
                        onTextChunk: escapableOnTextChunk
                    )
                }
                let duration = Date().timeIntervalSince(startTime)
                print("🌐 Claude Code CLI response in \(String(format: "%.1f", duration))s")
                return (text: responseText, duration: duration)
            } catch let claudeCodeError as ClaudeCodeError {
                // Retry once, but never after text reached the user (it would duplicate).
                let canRetry = claudeCodeError.isRetryable
                    && attemptNumber == 1
                    && !progress.hasReceivedText
                    && !Task.isCancelled
                guard canRetry else {
                    print("⚠️ Claude Code CLI failed: \(claudeCodeError.localizedDescription)")
                    throw claudeCodeError
                }
                print("🔁 Claude Code CLI failed (\(claudeCodeError.localizedDescription)), retrying once")
                attemptNumber += 1
            }
        }
    }

    // MARK: Request plumbing

    /// Tracks activity for the inactivity timeout and whether any text was streamed.
    private final class ResponseProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivityDate = Date()
        private var receivedText = false

        func recordActivity(receivedText didReceiveText: Bool = false) {
            lock.lock()
            lastActivityDate = Date()
            if didReceiveText { receivedText = true }
            lock.unlock()
        }

        var secondsSinceLastActivity: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(lastActivityDate)
        }

        var hasReceivedText: Bool {
            lock.lock(); defer { lock.unlock() }
            return receivedText
        }
    }

    /// The CLI's stream-json input only accepts user turns, so prior exchanges
    /// are folded into the text of the current turn.
    private func makeInputData(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> Data {
        var contentBlocks: [[String: Any]] = []
        if !conversationHistory.isEmpty {
            let historyText = conversationHistory.map { exchange in
                "user: \(exchange.userPlaceholder)\nyou: \(exchange.assistantResponse)"
            }.joined(separator: "\n\n")
            contentBlocks.append([
                "type": "text",
                "text": "earlier in this conversation:\n\n\(historyText)"
            ])
        }
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }
        contentBlocks.append(["type": "text", "text": userPrompt])

        let inputMessage: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": contentBlocks]
        ]
        var inputData = try JSONSerialization.data(withJSONObject: inputMessage)
        inputData.append(0x0A) // newline-delimited JSON
        return inputData
    }

    /// Sends the request to `claudeProcess` and streams the reply, racing an
    /// inactivity watchdog. Returns the final text.
    private func runRequest(
        on claudeProcess: ClaudeCodeProcess,
        inputData: Data,
        progress: ResponseProgress,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        // Write the request on a background queue; large screenshots can exceed
        // the pipe buffer, so this must not block the stdout reader below.
        DispatchQueue.global(qos: .userInitiated).async {
            try? claudeProcess.stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
            try? claudeProcess.stdinPipe.fileHandleForWriting.close()
        }
        progress.recordActivity()

        return try await withThrowingTaskGroup(of: String.self) { taskGroup in
            taskGroup.addTask {
                try await self.readResponse(from: claudeProcess, progress: progress, onTextChunk: onTextChunk)
            }
            taskGroup.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if progress.secondsSinceLastActivity > TimeInterval(Self.inactivityTimeoutSeconds) {
                        claudeProcess.terminate()
                        throw ClaudeCodeError.timedOut(seconds: Self.inactivityTimeoutSeconds)
                    }
                }
            }

            defer { taskGroup.cancelAll() }
            guard let firstFinishedResult = try await taskGroup.next() else {
                throw ClaudeCodeError.failed(details: "no response")
            }
            return firstFinishedResult
        }
    }

    private func readResponse(
        from claudeProcess: ClaudeCodeProcess,
        progress: ResponseProgress,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var accumulatedResponseText = ""
        var finalResultText: String?
        var finalResultError: String?

        try await withTaskCancellationHandler {
            for try await line in claudeProcess.stdoutPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                progress.recordActivity()
                guard let lineData = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let eventType = event["type"] as? String else {
                    continue
                }

                if eventType == "system", (event["subtype"] as? String) == "init" {
                    // "none" means the CLI is using the logged-in Claude subscription (OAuth),
                    // anything else (e.g. "ANTHROPIC_API_KEY") means pay-per-token API billing.
                    let apiKeySource = event["apiKeySource"] as? String ?? "unknown"
                    print("🔑 Claude Code auth: apiKeySource=\(apiKeySource)\(apiKeySource == "none" ? " (Claude subscription)" : " (API key billing!)")")
                } else if eventType == "stream_event",
                   let streamEvent = event["event"] as? [String: Any],
                   (streamEvent["type"] as? String) == "content_block_delta",
                   let delta = streamEvent["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let textChunk = delta["text"] as? String {
                    accumulatedResponseText += textChunk
                    progress.recordActivity(receivedText: true)
                    let currentAccumulatedText = accumulatedResponseText
                    await onTextChunk(currentAccumulatedText)
                } else if eventType == "result" {
                    if let usage = event["usage"] as? [String: Any] {
                        let inputTokens = usage["input_tokens"] as? Int ?? 0
                        let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                        let cacheWriteTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                        let outputTokens = usage["output_tokens"] as? Int ?? 0
                        print("📊 Tokens: input \(inputTokens) + cache read \(cacheReadTokens) + cache write \(cacheWriteTokens), output \(outputTokens)")
                    }
                    let resultText = event["result"] as? String
                    if (event["is_error"] as? Bool) == true || (event["subtype"] as? String) != "success" {
                        finalResultError = resultText ?? (event["subtype"] as? String) ?? "unknown error"
                    } else {
                        finalResultText = resultText
                    }
                }
            }
        } onCancel: {
            claudeProcess.terminate()
        }

        try Task.checkCancellation()

        if let finalResultError {
            throw ClaudeCodeError.classify(finalResultError)
        }

        if finalResultText == nil && accumulatedResponseText.isEmpty {
            let stderrData = (try? claudeProcess.stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw ClaudeCodeError.classify(stderrText.isEmpty ? "Claude Code exited without a response" : stderrText)
        }

        return finalResultText ?? accumulatedResponseText
    }

    // MARK: Diagnostics

    /// `claude --version`, or nil if the CLI can't be found or run.
    static func installedVersion() async -> String? {
        guard let claudeExecutablePath = locateClaudeExecutable() else { return nil }
        return await Task.detached {
            let versionProcess = Process()
            versionProcess.executableURL = URL(fileURLWithPath: claudeExecutablePath)
            versionProcess.arguments = ["--version"]
            let outputPipe = Pipe()
            versionProcess.standardOutput = outputPipe
            versionProcess.standardError = Pipe()
            do {
                try versionProcess.run()
            } catch {
                return nil
            }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            versionProcess.waitUntilExit()
            let versionText = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return versionText?.isEmpty == false ? versionText : nil
        }.value
    }

    /// Sends a tiny text-only request with Haiku to check the login works end to end.
    /// Returns the round-trip time.
    static func testConnection() async throws -> TimeInterval {
        let testClient = ClaudeCodeCLI(model: "haiku")
        testClient.usesWarmProcessPool = false
        let (_, duration) = try await testClient.analyzeImageStreaming(
            images: [],
            systemPrompt: "reply with exactly: ok",
            userPrompt: "ping",
            onTextChunk: { _ in }
        )
        return duration
    }
}
