//
//  MemoryStore.swift
//  leanring-buddy
//
//  Long-term memory: short facts about the user that YoClicky keeps between
//  sessions (e.g. "studies at ETH", "prefers answers in French"). Claude marks
//  a fact to keep by adding a [REMEMBER: ...] tag to its reply; the tag is
//  stripped before the reply is spoken or shown. Facts are stored locally in
//  ~/Library/Application Support/YoClicky/memories.json and sent along with
//  each question while memory is on (Settings > Privacy).
//

import Combine
import Foundation

struct MemoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
}

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// Oldest facts are dropped beyond this, to keep every request small.
    private static let maxMemoryCount = 30

    @Published private(set) var memories: [MemoryItem] = []

    private let storageURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("YoClicky", isDirectory: true)
        .appendingPathComponent("memories.json")

    private init() {
        load()
    }

    func add(_ factText: String) {
        let trimmedFact = factText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFact.isEmpty else { return }
        let isDuplicate = memories.contains { $0.text.caseInsensitiveCompare(trimmedFact) == .orderedSame }
        guard !isDuplicate else { return }

        memories.append(MemoryItem(id: UUID(), text: trimmedFact, createdAt: Date()))
        if memories.count > Self.maxMemoryCount {
            memories.removeFirst(memories.count - Self.maxMemoryCount)
        }
        print("🧠 Memory: remembered \"\(trimmedFact)\"")
        save()
    }

    func delete(_ memory: MemoryItem) {
        memories.removeAll { $0.id == memory.id }
        save()
    }

    func deleteAll() {
        memories = []
        save()
    }

    /// Text block sent with each question, or nil when there's nothing to send.
    var promptContext: String? {
        guard !memories.isEmpty else { return nil }
        let factLines = memories.map { "- \($0.text)" }.joined(separator: "\n")
        return "what you remember about the user from earlier sessions:\n\(factLines)"
    }

    // MARK: Tag parsing

    private static let rememberTagRegex = try! NSRegularExpression(pattern: #"\[REMEMBER:\s*([^\]]+?)\s*\]"#)

    /// Removes [REMEMBER: ...] tags from a reply and returns the facts they held.
    static func extractRememberTags(from responseText: String) -> (cleanedText: String, facts: [String]) {
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let facts = rememberTagRegex.matches(in: responseText, range: fullRange).compactMap { match -> String? in
            guard let factRange = Range(match.range(at: 1), in: responseText) else { return nil }
            return String(responseText[factRange])
        }
        let cleanedText = rememberTagRegex.stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanedText, facts)
    }

    // MARK: Persistence

    private func load() {
        guard let storedData = try? Data(contentsOf: storageURL),
              let storedMemories = try? JSONDecoder().decode([MemoryItem].self, from: storedData) else {
            return
        }
        memories = storedMemories
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(memories).write(to: storageURL, options: .atomic)
        } catch {
            print("⚠️ Memory: couldn't save: \(error)")
        }
    }
}
