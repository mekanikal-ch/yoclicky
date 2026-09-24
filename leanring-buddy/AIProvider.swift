//
//  AIProvider.swift
//  leanring-buddy
//
//  The AI backends Clicky can talk to. Only Claude (via the Claude Code CLI)
//  is implemented today; the others are listed as "coming soon" in the UI.
//
//  To add a provider:
//    1. Write a client that conforms to `AIProviderClient` (see ClaudeCodeCLI).
//    2. Return it from `makeClient(model:effort:)` below.
//    3. Set `isAvailable` to true and fill in its model options.
//

import Foundation

/// Anything that can answer a screenshot + prompt, streaming text as it arrives.
protocol AIProviderClient {
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)

    /// Optionally prepares for the next request (e.g. starts a process ahead of time).
    func prewarm(systemPrompt: String)
}

extension AIProviderClient {
    func prewarm(systemPrompt: String) {}
}

extension ClaudeCodeCLI: AIProviderClient {}

struct AIModelOption: Identifiable, Equatable {
    let label: String
    let modelID: String
    var id: String { modelID }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case chatGPT = "chatgpt"
    case gemini
    case grok
    case metaLlama = "meta"
    case localOllama = "ollama"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .metaLlama: return "Meta Llama"
        case .localOllama: return "Local (Ollama)"
        }
    }

    /// How the provider is reached and billed, shown in settings.
    var connectionDescription: String {
        switch self {
        case .claude: return "Claude Code CLI, uses your Claude subscription"
        case .chatGPT: return "Codex CLI, would use your ChatGPT subscription"
        case .gemini: return "Gemini CLI, would use your Google account"
        case .grok: return "xAI API key, pay per use"
        case .metaLlama: return "Llama API key"
        case .localOllama: return "Runs on this Mac, free and private"
        }
    }

    /// Whether a working client exists. Unavailable providers show as "coming soon".
    var isAvailable: Bool {
        switch self {
        case .claude: return true
        case .chatGPT, .gemini, .grok, .metaLlama, .localOllama: return false
        }
    }

    var modelOptions: [AIModelOption] {
        switch self {
        case .claude:
            // CLI aliases: each always runs the newest model of that family.
            // "Auto" picks Sonnet or Opus per question (ResponseRouter).
            return [
                AIModelOption(label: "Auto", modelID: ResponseRouter.autoModelID),
                AIModelOption(label: "Haiku", modelID: "haiku"),
                AIModelOption(label: "Sonnet", modelID: "sonnet"),
                AIModelOption(label: "Opus", modelID: "opus")
            ]
        case .chatGPT, .gemini, .grok, .metaLlama, .localOllama:
            return []
        }
    }

    var defaultModelID: String {
        switch self {
        case .claude: return ResponseRouter.autoModelID
        default: return modelOptions.first?.modelID ?? ""
        }
    }

    /// Builds the client used for one request. Only called for available providers.
    func makeClient(model: String, effort: String) -> AIProviderClient {
        switch self {
        case .claude:
            return ClaudeCodeCLI(model: model, effort: effort)
        case .chatGPT, .gemini, .grok, .metaLlama, .localOllama:
            preconditionFailure("\(displayName) is not implemented yet")
        }
    }

    /// Starts processes ahead of time for the plans a next question will likely use.
    func prewarm(plans: [ResponsePlan], systemPrompt: String) {
        switch self {
        case .claude:
            ClaudeCodeCLI.prewarm(
                configurations: plans.map { (model: $0.modelAlias, effort: $0.effort) },
                systemPrompt: systemPrompt
            )
        case .chatGPT, .gemini, .grok, .metaLlama, .localOllama:
            break
        }
    }
}

enum AIProviderSettings {
    static let selectedProviderKey = "selectedAIProvider"

    static var selectedProvider: AIProvider {
        get {
            let storedProvider = UserDefaults.standard.string(forKey: selectedProviderKey).flatMap(AIProvider.init(rawValue:))
            guard let storedProvider, storedProvider.isAvailable else { return .claude }
            return storedProvider
        }
        set {
            guard newValue.isAvailable else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
        }
    }

    /// Model per provider. Claude keeps its original "selectedClaudeModel" key so
    /// existing choices carry over.
    private static func modelKey(for provider: AIProvider) -> String {
        provider == .claude ? "selectedClaudeModel" : "selectedModel.\(provider.rawValue)"
    }

    static func selectedModel(for provider: AIProvider) -> String {
        guard let storedModel = UserDefaults.standard.string(forKey: modelKey(for: provider)) else {
            return provider.defaultModelID
        }
        // Older versions stored full IDs like "claude-sonnet-4-6"; map them to
        // the alias options so the picker still shows the choice.
        if provider == .claude && !provider.modelOptions.contains(where: { $0.modelID == storedModel }) {
            return ClaudeCodeCLI.modelAlias(for: storedModel)
        }
        return storedModel
    }

    static func setSelectedModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model, forKey: modelKey(for: provider))
    }
}
