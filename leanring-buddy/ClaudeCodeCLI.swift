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

import Foundation

/// Drop-in replacement for `ClaudeAPI.analyzeImageStreaming` backed by the Claude Code CLI.
class ClaudeCodeCLI {
    var model: String

    init(model: String = "sonnet") {
        self.model = model
    }

    /// Maps the app's stored model IDs (e.g. "claude-sonnet-4-6") to CLI aliases
    /// so the CLI always uses the latest model of that family.
    private var cliModelAlias: String {
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
            throw NSError(
                domain: "ClaudeCodeCLI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Claude Code CLI not found. Install it and run `claude` once to log in."]
            )
        }

        // The CLI's stream-json input only accepts user turns, so prior exchanges
        // are folded into the text of the current turn.
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudeExecutablePath)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", cliModelAlias,
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

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let payloadMB = Double(inputData.count) / 1_048_576.0
        print("🌐 Claude Code CLI request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s), model \(cliModelAlias)")

        try process.run()

        // Write the request on a background queue; large screenshots can exceed
        // the pipe buffer, so this must not block the stdout reader below.
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        var accumulatedResponseText = ""
        var finalResultText: String?
        var finalResultError: String?

        try await withTaskCancellationHandler {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
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
            if process.isRunning { process.terminate() }
        }

        if let finalResultError {
            throw NSError(
                domain: "ClaudeCodeCLI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Claude Code error: \(finalResultError)"]
            )
        }

        if finalResultText == nil && accumulatedResponseText.isEmpty {
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ClaudeCodeCLI",
                code: Int(process.isRunning ? -1 : process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Claude Code returned no response. \(stderrText)"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        print("🌐 Claude Code CLI response in \(String(format: "%.1f", duration))s")
        return (text: finalResultText ?? accumulatedResponseText, duration: duration)
    }
}
