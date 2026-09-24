//
//  ResponseRouter.swift
//  leanring-buddy
//
//  Picks the model, the thinking effort and the screenshot size for each
//  question. With the "Auto" model, everyday questions go to Sonnet and
//  questions with math, code or a "why" go to Opus, which is more reliable
//  at them (in testing Sonnet got simple time arithmetic wrong about half the
//  time while Opus never did) for about a second more. Asking for detail
//  ("step by step", "in depth"…) or asking about the open document also
//  raises the effort.
//

import Foundation

/// How much reasoning a question needs.
enum ResponseRoute: String {
    /// Most questions: "what's this", "where is…", "how do I…".
    case standard
    /// Math, numbers, code, errors, "why" and "explain" questions.
    case reasoning
    /// The user explicitly asked for depth, or the question is about a whole document.
    case deepDive
}

/// Everything decided for one request.
struct ResponsePlan: Equatable {
    let route: ResponseRoute
    /// Claude Code CLI model alias ("haiku", "sonnet", "opus"). Aliases always
    /// resolve to the newest model of that family.
    let modelAlias: String
    /// Claude Code CLI `--effort` level.
    let effort: String

    /// Claude 4.7 and later read images up to 2576 px / 4784 visual tokens
    /// without downscaling; Haiku 4.5 is on the standard tier (1568 px / 1568
    /// tokens). Images over the limit get downscaled by the server, which would
    /// shift [POINT] coordinates, so screenshots must stay under it.
    var supportsHighResolutionImages: Bool {
        modelAlias != "haiku"
    }

    /// Long edge of each full screenshot, in pixels.
    func screenshotMaxLongEdge(useCavemanMode: Bool) -> Int {
        if useCavemanMode { return 1024 }
        return supportsHighResolutionImages ? 1920 : 1280
    }

    /// Visual-token budget per image (one token per 28x28 pixel patch).
    var maxVisualTokensPerImage: Int {
        supportsHighResolutionImages ? 4784 : 1568
    }
}

enum ResponseRouter {
    static let autoModelID = "auto"

    /// Explicit requests for depth (English + French).
    private static let deepDivePhrases = [
        "in detail", "in depth", "step by step", "think hard", "think carefully", "think it through",
        "deep dive", "thorough", "thoroughly", "walk me through", "break it down", "explain everything",
        "en détail", "en profondeur", "étape par étape", "réfléchis", "approfondi", "explique tout"
    ]

    /// Words that suggest the answer needs careful reasoning (English + French).
    private static let reasoningWords = [
        "why", "explain", "how does", "how come", "debug", "bug", "error", "errors", "fix",
        "wrong", "solve", "calculate", "compute", "prove", "derive", "compare", "difference", "versus",
        "percent", "percentage", "average", "total", "sum", "multiply", "divide", "divided", "times",
        "plus", "minus", "equation", "formula", "math", "code", "function", "algorithm", "regex",
        "sql", "convert", "translate",
        "pourquoi", "explique", "expliquer", "comment ça", "erreur", "résous", "résoudre", "calcule",
        "calculer", "compare", "différence", "pourcentage", "moyenne", "somme", "fois", "moins",
        "divisé", "équation", "formule", "traduis", "convertis"
    ]

    private static let deepDiveRegex = wordBoundaryRegex(for: deepDivePhrases)
    private static let reasoningRegex = wordBoundaryRegex(for: reasoningWords)

    private static func wordBoundaryRegex(for phrases: [String]) -> NSRegularExpression {
        let alternatives = phrases.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(\(alternatives))\\b", options: [.caseInsensitive])
    }

    static func route(for question: String, includesOpenDocument: Bool) -> ResponseRoute {
        let fullRange = NSRange(question.startIndex..., in: question)
        let wordCount = question.split(whereSeparator: \.isWhitespace).count

        if includesOpenDocument || deepDiveRegex.firstMatch(in: question, range: fullRange) != nil {
            return .deepDive
        }
        // Any digit hints at arithmetic, dates or quantities, where Opus is more reliable.
        let containsDigit = question.contains(where: \.isNumber)
        if containsDigit || wordCount > 40 || reasoningRegex.firstMatch(in: question, range: fullRange) != nil {
            return .reasoning
        }
        return .standard
    }

    /// Model + effort for a question, given the model picked in settings.
    static func plan(
        question: String,
        selectedModelID: String,
        useCavemanMode: Bool,
        includesOpenDocument: Bool
    ) -> ResponsePlan {
        let route = route(for: question, includesOpenDocument: includesOpenDocument)
        return plan(for: route, selectedModelID: selectedModelID, useCavemanMode: useCavemanMode)
    }

    static func plan(for route: ResponseRoute, selectedModelID: String, useCavemanMode: Bool) -> ResponsePlan {
        let modelAlias: String
        if selectedModelID == autoModelID {
            // Caveman mode is about saving the plan, so it stays on Sonnet.
            modelAlias = (route == .standard || useCavemanMode) ? "sonnet" : "opus"
        } else {
            modelAlias = ClaudeCodeCLI.modelAlias(for: selectedModelID)
        }
        // "high" rather than "medium": in testing, medium made Sonnet skip the
        // checking that got short calculations right, for no speed gain.
        let effort = route == .deepDive ? "xhigh" : "high"
        return ResponsePlan(route: route, modelAlias: modelAlias, effort: effort)
    }

    /// The plans worth keeping a warm process for, most likely first.
    static func plansToPrewarm(selectedModelID: String, useCavemanMode: Bool) -> [ResponsePlan] {
        let standardPlan = plan(for: .standard, selectedModelID: selectedModelID, useCavemanMode: useCavemanMode)
        let reasoningPlan = plan(for: .reasoning, selectedModelID: selectedModelID, useCavemanMode: useCavemanMode)
        let bothUseTheSameProcess = standardPlan.modelAlias == reasoningPlan.modelAlias
            && standardPlan.effort == reasoningPlan.effort
        return bothUseTheSameProcess ? [standardPlan] : [standardPlan, reasoningPlan]
    }
}
