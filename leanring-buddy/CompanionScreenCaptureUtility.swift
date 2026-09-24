//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// JPEG quality: high enough that small text survives compression.
    private static let jpegCompressionFactor = 0.85

    /// Claude sees images as 28x28 pixel patches ("visual tokens").
    private static let visualTokenPatchSize = 28

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors. `maxDimension` caps the long edge
    /// in pixels (smaller = fewer image tokens); `maxVisualTokens` caps the
    /// image's token count so the model never downscales it (which would shift
    /// pointing coordinates); `onlyCursorScreen` skips other displays.
    static func captureAllScreensAsJPEG(
        maxDimension: Int = 1280,
        maxVisualTokens: Int = 1568,
        onlyCursorScreen: Bool = false
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []
        let displaysToCapture = onlyCursorScreen ? Array(sortedDisplays.prefix(1)) : sortedDisplays

        for (displayIndex, display) in displaysToCapture.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let screenshotSize = screenshotPixelSize(
                displayWidth: display.width,
                displayHeight: display.height,
                maxLongEdge: maxDimension,
                maxVisualTokens: maxVisualTokens
            )
            configuration.width = screenshotSize.width
            configuration.height = screenshotSize.height

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else {
                continue
            }

            let screenLabel: String
            if displaysToCapture.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// The largest screenshot size with the display's aspect ratio whose long
    /// edge is at most `maxLongEdge` and whose visual-token count fits `maxVisualTokens`.
    static func screenshotPixelSize(displayWidth: Int, displayHeight: Int, maxLongEdge: Int, maxVisualTokens: Int) -> (width: Int, height: Int) {
        let aspectRatio = CGFloat(displayWidth) / CGFloat(displayHeight)
        var longEdge = maxLongEdge
        while true {
            let width = displayWidth >= displayHeight ? longEdge : Int(CGFloat(longEdge) * aspectRatio)
            let height = displayWidth >= displayHeight ? Int(CGFloat(longEdge) / aspectRatio) : longEdge
            let visualTokens = Int(ceil(Double(width) / Double(visualTokenPatchSize)))
                * Int(ceil(Double(height) / Double(visualTokenPatchSize)))
            if visualTokens <= maxVisualTokens || longEdge <= 512 {
                return (width, height)
            }
            longEdge -= 32
        }
    }

    /// Size of the close-up around the cursor, in screen points.
    private static let cursorCloseUpSizeInPoints = CGSize(width: 560, height: 360)

    /// Captures the area around the mouse cursor at 2x (Retina) sharpness, so
    /// small text the user is looking at stays readable even though the full
    /// screenshot is downscaled. Nil if the cursor's display can't be found.
    static func captureCursorCloseUpAsJPEG() async throws -> Data? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouseLocation = NSEvent.mouseLocation

        guard let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let cursorDisplayID = cursorScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let cursorDisplay = content.displays.first(where: { $0.displayID == cursorDisplayID }) else {
            return nil
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let filter = SCContentFilter(display: cursorDisplay, excludingWindows: ownAppWindows)

        // sourceRect is in the display's own point space with a top-left origin,
        // while the mouse location is global AppKit (bottom-left origin).
        let screenFrame = cursorScreen.frame
        let cursorXInDisplay = mouseLocation.x - screenFrame.minX
        let cursorYInDisplay = screenFrame.maxY - mouseLocation.y
        let closeUpWidth = min(cursorCloseUpSizeInPoints.width, screenFrame.width)
        let closeUpHeight = min(cursorCloseUpSizeInPoints.height, screenFrame.height)
        let closeUpOriginX = min(max(0, cursorXInDisplay - closeUpWidth / 2), screenFrame.width - closeUpWidth)
        let closeUpOriginY = min(max(0, cursorYInDisplay - closeUpHeight / 2), screenFrame.height - closeUpHeight)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: closeUpOriginX, y: closeUpOriginY, width: closeUpWidth, height: closeUpHeight)
        configuration.width = Int(closeUpWidth * 2)
        configuration.height = Int(closeUpHeight * 2)

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor])
    }
}
