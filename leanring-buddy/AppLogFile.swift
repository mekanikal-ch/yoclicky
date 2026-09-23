//
//  AppLogFile.swift
//  leanring-buddy
//
//  Sends the app's print() output to ~/Library/Logs/YoClicky/yoclicky.log when
//  it isn't launched from a terminal, so problems can be diagnosed later from
//  Settings > General > Open Logs. The file is rotated once it passes 5 MB.
//

import AppKit
import Foundation

enum AppLogFile {
    private static let maxLogFileBytes = 5 * 1024 * 1024

    static var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/YoClicky", isDirectory: true)
    }

    static var logFileURL: URL {
        logDirectoryURL.appendingPathComponent("yoclicky.log")
    }

    /// Redirects stdout/stderr to the log file. Skipped when attached to a
    /// terminal so `YoClicky.app/Contents/MacOS/YoClicky` still prints live.
    static func redirectOutputIfNeeded() {
        guard isatty(STDOUT_FILENO) == 0 else { return }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        if let fileAttributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
           let fileSize = fileAttributes[.size] as? Int,
           fileSize > maxLogFileBytes {
            let previousLogURL = logDirectoryURL.appendingPathComponent("yoclicky.previous.log")
            try? fileManager.removeItem(at: previousLogURL)
            try? fileManager.moveItem(at: logFileURL, to: previousLogURL)
        }

        freopen(logFileURL.path, "a", stdout)
        freopen(logFileURL.path, "a", stderr)
        // Line-buffered so each print() lands in the file right away.
        setvbuf(stdout, nil, _IOLBF, 0)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        print("\n===== YoClicky \(version) started \(Date()) =====")
    }

    /// Opens the log in Console.app (the default viewer for .log files).
    static func openInViewer() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logFileURL.path, contents: Data())
        }
        NSWorkspace.shared.open(logFileURL)
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }
}
