//
//  GlassStyle.swift
//  leanring-buddy
//
//  Liquid Glass look (macOS 26 Tahoe): windows are backed by NSGlassEffectView,
//  controls use SwiftUI's glassEffect, and colors are semantic so everything
//  adapts to light and dark mode. On macOS 14-15 it falls back to the classic
//  translucent materials (NSVisualEffectView / .ultraThinMaterial).
//

import AppKit
import SwiftUI

extension DS {
    enum Glass {
        /// Tint for prominent buttons and selected states.
        static let accentFill = Color.accentColor
        static let accentStroke = Color.accentColor.opacity(0.6)
        /// Faint fill for secondary controls sitting on glass.
        static let subtleFill = Color.primary.opacity(0.07)
        /// Hairline borders on glass.
        static let hairline = Color.primary.opacity(0.12)

        static let windowCornerRadius: CGFloat = 18

        /// How opaque window glass is (0 = fully see-through glass, 1 = solid).
        /// Adjustable in Settings > Appearance.
        static let windowOpacityKey = "glassWindowOpacity"
        static let defaultWindowOpacity = 0.75

        static var windowOpacity: Double {
            UserDefaults.standard.object(forKey: windowOpacityKey) as? Double ?? defaultWindowOpacity
        }
    }
}

// MARK: - Window backing

/// Content view for a window: a full-size glass (or blur) layer behind a SwiftUI
/// hosting view. Reports the hosting view's fitting size so auto-sized panels
/// still wrap their SwiftUI content.
final class GlassBackedContentView: NSView {
    let hostingView: NSView
    private var backgroundView: NSView?
    private var opacityObserver: NSObjectProtocol?

    init<Content: View>(rootView: Content, cornerRadius: CGFloat = DS.Glass.windowCornerRadius) {
        let swiftUIHostingView = NSHostingView(rootView: rootView)
        self.hostingView = swiftUIHostingView
        super.init(frame: .zero)

        let backgroundView: NSView
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.cornerRadius = cornerRadius
            backgroundView = glassView
        } else {
            let visualEffectView = NSVisualEffectView()
            visualEffectView.material = .popover
            visualEffectView.blendingMode = .behindWindow
            visualEffectView.state = .active
            visualEffectView.wantsLayer = true
            visualEffectView.layer?.cornerRadius = cornerRadius
            visualEffectView.layer?.masksToBounds = true
            backgroundView = visualEffectView
        }

        self.backgroundView = backgroundView
        applyWindowOpacity()
        // Re-tint live when the opacity slider in Settings moves.
        opacityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyWindowOpacity()
        }

        for subview in [backgroundView, swiftUIHostingView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: trailingAnchor),
                subview.topAnchor.constraint(equalTo: topAnchor),
                subview.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let opacityObserver {
            NotificationCenter.default.removeObserver(opacityObserver)
        }
    }

    override var fittingSize: NSSize {
        hostingView.fittingSize
    }

    /// Tints the glass with the window background color so text stays readable.
    /// The tint follows light/dark mode because it's a dynamic system color.
    private func applyWindowOpacity() {
        let tintColor = NSColor.windowBackgroundColor.withAlphaComponent(DS.Glass.windowOpacity)
        if #available(macOS 26.0, *), let glassView = backgroundView as? NSGlassEffectView {
            glassView.tintColor = tintColor
        } else if let visualEffectView = backgroundView as? NSVisualEffectView {
            visualEffectView.wantsLayer = true
            visualEffectView.alphaValue = 1
            visualEffectView.layer?.backgroundColor = tintColor.cgColor
        }
    }
}

extension NSWindow {
    /// Makes the window itself invisible so only the glass content view shows.
    func makeTransparentForGlass() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }
}

// MARK: - SwiftUI glass

extension View {
    /// Liquid Glass behind this view in `shape`, optionally tinted and reacting to touch.
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background(shape.fill(tint ?? Color.clear))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(DS.Glass.hairline, lineWidth: 0.5))
        }
    }

    /// Rounded glass card, used for grouped content.
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        glassBackground(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Button styles

/// Blue-tinted glass capsule for primary actions.
struct GlassProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .glassBackground(Capsule(), tint: DS.Glass.accentFill, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Clear glass capsule for secondary actions.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassBackground(Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Segmented control

/// One segment of a glass segmented control; the selected one is a filled accent pill.
struct GlassSegment: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? DS.Glass.accentFill : Color.clear)
                )
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// Glass capsule holding a row of GlassSegments.
struct GlassSegmentedControl<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(2)
        .fixedSize()
        .glassBackground(Capsule())
    }
}
