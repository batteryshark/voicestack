import SwiftUI
import AppKit

/// The pill's look. Graphite is dark smoked glass (the default); Frost is light frosted glass. Both sit on the system's
/// behind-window blur in the app (NSVisualEffectView); stills simulate that blur from a wallpaper.
public struct PillTheme: Sendable {
    public enum Name: String, Sendable, CaseIterable { case graphite, frost }

    public let name: Name
    /// The material the app puts behind the content, and the appearance it is drawn in.
    public let material: NSVisualEffectView.Material
    public let appearance: NSAppearance.Name
    /// Simulated material for stills: how much the blurred backdrop is washed toward `materialWash`.
    public let materialWash: Color
    public let materialWashOpacity: Double
    /// Tint laid over the material, then the edges.
    public let tint: Color
    public let outerStroke: Color
    public let innerHighlight: Color
    public let innerShade: Color

    public let primary: Color
    public let secondary: Color
    public let tail: Color

    public let you: Color
    /// Shared violet in graphite; a darker shade keeps the label legible on Frost's light glass.
    public var external: Color { name == .graphite ? Color(red: 0.76, green: 0.65, blue: 1) : Color(red: 0.46, green: 0.28, blue: 0.72) }
    public let youDeep: Color
    public let chief: Color
    public let chiefDeep: Color
    public let idle: Color
    public let error: Color
    public let ready: Color

    public let buttonFill: Color
    public let buttonHover: Color
    public let buttonStroke: Color
    public let glyph: Color
    public let activeFill: Color
    public let activeGlyph: Color
    /// Text on an accent-filled button (Start, Send).
    public let onAccent: Color
    /// The selected segment of a segmented choice.
    public let segmentFill: Color
    public let segmentText: Color
    public let groupFill: Color
    public let groupStroke: Color
    public let divider: Color
    public let glow: Double
    public let colorScheme: ColorScheme

    public static func named(_ name: Name) -> PillTheme { name == .frost ? frost : graphite }

    public static let graphite = PillTheme(
        name: .graphite, material: .hudWindow, appearance: .darkAqua,
        materialWash: Color(red: 0.12, green: 0.12, blue: 0.13), materialWashOpacity: 0.70,
        tint: Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.38),
        outerStroke: Color.black.opacity(0.55), innerHighlight: Color.white.opacity(0.20), innerShade: Color.white.opacity(0.05),
        primary: Color.white.opacity(0.96), secondary: Color.white.opacity(0.56), tail: Color.white.opacity(0.40),
        you: Color(red: 0.42, green: 0.73, blue: 1.0), youDeep: Color(red: 0.24, green: 0.52, blue: 1.0),
        chief: Color(red: 1.0, green: 0.72, blue: 0.36), chiefDeep: Color(red: 1.0, green: 0.50, blue: 0.27),
        idle: Color.white.opacity(0.28), error: Color(red: 1.0, green: 0.39, blue: 0.37), ready: Color(red: 0.30, green: 0.86, blue: 0.47),
        buttonFill: Color.white.opacity(0.09), buttonHover: Color.white.opacity(0.17), buttonStroke: Color.white.opacity(0.13),
        glyph: Color.white.opacity(0.92), activeFill: Color.white.opacity(0.92), activeGlyph: Color.black.opacity(0.82),
        onAccent: Color(red: 0.03, green: 0.09, blue: 0.20),
        segmentFill: Color.white.opacity(0.92), segmentText: Color.black.opacity(0.82),
        groupFill: Color.white.opacity(0.055), groupStroke: Color.white.opacity(0.07), divider: Color.white.opacity(0.08),
        glow: 0.55, colorScheme: .dark)

    public static let frost = PillTheme(
        name: .frost, material: .popover, appearance: .aqua,
        materialWash: Color(red: 0.97, green: 0.97, blue: 0.98), materialWashOpacity: 0.66,
        tint: Color.white.opacity(0.30),
        outerStroke: Color.black.opacity(0.14), innerHighlight: Color.white.opacity(0.85), innerShade: Color.white.opacity(0.25),
        primary: Color.black.opacity(0.86), secondary: Color.black.opacity(0.50), tail: Color.black.opacity(0.36),
        you: Color(red: 0.13, green: 0.47, blue: 0.96), youDeep: Color(red: 0.36, green: 0.30, blue: 0.95),
        chief: Color(red: 0.93, green: 0.45, blue: 0.10), chiefDeep: Color(red: 0.92, green: 0.27, blue: 0.24),
        idle: Color.black.opacity(0.22), error: Color(red: 0.88, green: 0.18, blue: 0.20), ready: Color(red: 0.16, green: 0.70, blue: 0.33),
        buttonFill: Color.black.opacity(0.055), buttonHover: Color.black.opacity(0.10), buttonStroke: Color.black.opacity(0.07),
        glyph: Color.black.opacity(0.78), activeFill: Color.black.opacity(0.80), activeGlyph: Color.white,
        onAccent: Color.white,
        segmentFill: Color.white, segmentText: Color.black.opacity(0.85),
        groupFill: Color.white.opacity(0.45), groupStroke: Color.black.opacity(0.06), divider: Color.black.opacity(0.07),
        glow: 0.25, colorScheme: .light)
}

private struct PillThemeKey: EnvironmentKey { static let defaultValue = PillTheme.graphite }

extension EnvironmentValues {
    public var pillTheme: PillTheme {
        get { self[PillThemeKey.self] }
        set { self[PillThemeKey.self] = newValue }
    }
}

/// What is behind the pill when there is no real window: stills draw a blurred wallpaper here. `origin` is where the
/// pill's top-left sits on that image (points). In the app this is nil and the system blur shows through.
public struct PillBackdrop {
    public let image: NSImage
    public let origin: CGPoint
    public init(image: NSImage, origin: CGPoint) { self.image = image; self.origin = origin }
}

private struct PillBackdropKey: EnvironmentKey { static let defaultValue: PillBackdrop? = nil }

extension EnvironmentValues {
    public var pillBackdrop: PillBackdrop? {
        get { self[PillBackdropKey.self] }
        set { self[PillBackdropKey.self] = newValue }
    }
}
