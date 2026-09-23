//
//  AIProvider.swift
//  leanring-buddy
//
//  The AI backends Clicky can talk to. Only Claude (via the Claude Code CLI)
//  is implemented today; the others are listed as "coming soon" in the UI.
//
//  To add a provider:
//    1. Write a client that conforms to `AIProviderClient` (see ClaudeCodeCLI).
//    2. Return it from `makeClient(model:)` below.
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
            return [
                AIModelOption(label: "Haiku", modelID: "claude-haiku-4-5"),
                AIModelOption(label: "Sonnet", modelID: "claude-sonnet-4-6"),
                AIModelOption(label: "Opus", modelID: "claude-opus-4-6")
            ]
        case .chatGPT, .gemini, .grok, .metaLlama, .localOllama:
            return []
        }
    }

    var defaultModelID: String {
        switch self {
        case .claude: return "claude-sonnet-4-6"
        default: return modelOptions.first?.modelID ?? ""
        }
    }

    /// Builds the client used for one request. Only called for available providers.
    func makeClient(model: String) -> AIProviderClient {
        switch self {
        case .claude:
            return ClaudeCodeCLI(model: model)
        case .chatGPT, .gemini, .grok, .metaLlama, .localOllama:
            preconditionFailure("\(displayName) is not implemented yet")
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
        UserDefaults.standard.string(forKey: modelKey(for: provider)) ?? provider.defaultModelID
    }

    static func setSelectedModel(_ model: String, for provider: AIProvider) {
        UserDefaults.standard.set(model, forKey: modelKey(for: provider))
    }
}
