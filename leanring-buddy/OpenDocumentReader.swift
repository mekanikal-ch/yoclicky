//
//  OpenDocumentReader.swift
//  leanring-buddy
//
//  Finds the file open in the app the user is looking at (via the window's
//  Accessibility "document" attribute, which Preview, TextEdit, Xcode, Pages,
//  Word and most document-based apps expose) and extracts its text, so
//  YoClicky can answer about the whole document, not just the visible part.
//
//  Only used when the question is about the document (see
//  `isQuestionAboutDocument`), and capped in size, to avoid spending tokens
//  on every question.
//

import AppKit
import ApplicationServices
import PDFKit
import UniformTypeIdentifiers

struct OpenDocument {
    let fileName: String
    let text: String
    let wasTruncated: Bool
}

enum OpenDocumentReader {
    /// Files bigger than this aren't read at all.
    private static let maxFileBytes = 50 * 1024 * 1024

    /// Words that suggest the question is about the open file (English + French).
    private static let documentKeywords = [
        "document", "this file", "the file", "pdf", "this page", "these pages", "whole", "entire",
        "full text", "summarize", "summarise", "summary", "chapter", "section", "paper", "article",
        "slides", "report", "essay", "this code", "this script", "read it", "read this",
        "fichier", "ce doc", "résume", "resume", "résumé", "chapitre", "article", "entier", "en entier",
        "rapport", "lis ", "lire"
    ]

    static func isQuestionAboutDocument(_ question: String) -> Bool {
        let lowercasedQuestion = question.lowercased()
        return documentKeywords.contains(where: lowercasedQuestion.contains)
    }

    /// The document open in `application`'s focused (or main) window, with up
    /// to `maxCharacters` of its text. Nil if the app doesn't expose a file or
    /// the file type can't be read.
    static func readOpenDocument(in application: NSRunningApplication, maxCharacters: Int) -> OpenDocument? {
        guard let documentURL = documentURL(for: application) else {
            print("📄 Open document: \(application.localizedName ?? "app") exposes no file")
            return nil
        }
        guard let fullText = extractText(from: documentURL), !fullText.isEmpty else {
            print("📄 Open document: couldn't read text from \(documentURL.lastPathComponent)")
            return nil
        }

        let wasTruncated = fullText.count > maxCharacters
        let text = wasTruncated ? String(fullText.prefix(maxCharacters)) : fullText
        print("📄 Open document: \(documentURL.lastPathComponent), \(text.count) characters\(wasTruncated ? " (truncated)" : "")")
        return OpenDocument(fileName: documentURL.lastPathComponent, text: text, wasTruncated: wasTruncated)
    }

    private static func documentURL(for application: NSRunningApplication) -> URL? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)

        for windowAttribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(applicationElement, windowAttribute as CFString, &windowValue) == .success,
                  let windowValue,
                  CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
                continue
            }
            let windowElement = windowValue as! AXUIElement

            var documentValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString, &documentValue) == .success,
               let documentURLString = documentValue as? String,
               let documentURL = URL(string: documentURLString),
               documentURL.isFileURL {
                return documentURL
            }
        }
        return nil
    }

    private static func extractText(from fileURL: URL) -> String? {
        if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = fileAttributes[.size] as? Int,
           fileSize > maxFileBytes {
            return nil
        }

        let fileType = UTType(filenameExtension: fileURL.pathExtension)

        if fileType?.conforms(to: .pdf) == true {
            return PDFDocument(url: fileURL)?.string
        }

        let richTextTypes: [UTType] = [.rtf, .rtfd, .html]
        let wordExtensions: Set<String> = ["doc", "docx", "odt"]
        if let fileType, richTextTypes.contains(where: { fileType.conforms(to: $0) })
            || wordExtensions.contains(fileURL.pathExtension.lowercased()) {
            return (try? NSAttributedString(url: fileURL, options: [:], documentAttributes: nil))?.string
        }

        if fileType?.conforms(to: .text) == true || fileType?.conforms(to: .sourceCode) == true || fileType == nil {
            if let utf8Text = try? String(contentsOf: fileURL, encoding: .utf8) {
                return utf8Text
            }
            var detectedEncoding = String.Encoding.utf8
            return try? String(contentsOf: fileURL, usedEncoding: &detectedEncoding)
        }

        return nil
    }
}

/// Remembers the last app the user was in that isn't YoClicky, so opening the
/// chat window (which makes YoClicky frontmost) doesn't hide their document.
@MainActor
final class FrontmostApplicationTracker {
    private(set) var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    func start() {
        recordIfExternal(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.recordIfExternal(activatedApplication)
            }
        }
    }

    private func recordIfExternal(_ application: NSRunningApplication?) {
        guard let application, application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = application
    }
}
