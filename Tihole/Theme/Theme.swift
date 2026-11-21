import SwiftUI
import TiholeCore

/// A set of semantic color tokens. Screens ask for `surface`, `accent`, or
/// `block` and the active theme resolves them, so switching themes re-colors
/// the whole app at once. The palettes are the same ones the tihole TUI ships.
struct Theme: Equatable {
    var name: String
    var isDark: Bool

    /// App background.
    var surface: Color
    /// Raised surface: cards, list rows, bars.
    var panel: Color
    /// Primary foreground.
    var text: Color
    /// Muted foreground: secondary text, hints.
    var subtle: Color
    /// Brand, focus, and selection highlight.
    var accent: Color
    /// Positive / allowed.
    var allow: Color
    /// Negative / blocked.
    var block: Color
    /// Caution.
    var warn: Color
    /// Panel and divider borders.
    var border: Color
    /// Optional multi-stop signature gradient.
    var ramp: [Color] = []

    /// The signature gradient: the ramp when it has at least two stops,
    /// otherwise a plain accent-to-allow blend.
    var gradientStops: [Color] {
        ramp.count >= 2 ? ramp : [accent, allow]
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: gradientStops, startPoint: .leading, endPoint: .trailing)
    }

    func color(for tone: Tone) -> Color {
        switch tone {
        case .allow: return allow
        case .block: return block
        case .warn: return warn
        case .neutral: return text
        }
    }

    /// Green below 60%, amber below 85%, red above: the health-gauge scale.
    func healthColor(fraction: Double) -> Color {
        if fraction < 0.60 {
            return allow
        }
        if fraction < 0.85 {
            return warn
        }
        return block
    }
}

extension Color {
    /// A color from a 24-bit RGB hex value, e.g. `Color(hex: 0xFF2E93)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Built-in themes

extension Theme {
    /// tihole's signature dark theme: hot pink on a deep-void surface, with a
    /// pink-to-acid ramp for the wordmark.
    static let gloss = Theme(
        name: "gloss",
        isDark: true,
        surface: Color(hex: 0x0B0412),
        panel: Color(hex: 0x190A2E),
        text: Color(hex: 0xF4F1FB),
        subtle: Color(hex: 0x9E8FC6),
        accent: Color(hex: 0xFF2E93),
        allow: Color(hex: 0x5CF07A),
        block: Color(hex: 0xFF4D6D),
        warn: Color(hex: 0xF5B93D),
        border: Color(hex: 0x3A1E63),
        ramp: [
            Color(hex: 0xFF2E93),
            Color(hex: 0xE533C9),
            Color(hex: 0x6B2FE0),
            Color(hex: 0x2EE6FF),
            Color(hex: 0xD6FF2E),
        ]
    )

    /// Midnight navy with a soft periwinkle accent.
    static let deepNight = Theme(
        name: "deep-night",
        isDark: true,
        surface: Color(hex: 0x0B0F1A),
        panel: Color(hex: 0x141B2D),
        text: Color(hex: 0xE6EAF2),
        subtle: Color(hex: 0x8A93A6),
        accent: Color(hex: 0x7AA2F7),
        allow: Color(hex: 0x4ADE80),
        block: Color(hex: 0xF7768E),
        warn: Color(hex: 0xF5C97B),
        border: Color(hex: 0x2A3550)
    )

    /// Warm ivory paper with a brass accent.
    static let lightLuxury = Theme(
        name: "light-luxury",
        isDark: false,
        surface: Color(hex: 0xFBF9F4),
        panel: Color(hex: 0xFFFFFF),
        text: Color(hex: 0x1F1B16),
        subtle: Color(hex: 0x6E665B),
        accent: Color(hex: 0xB08D57),
        allow: Color(hex: 0x3F9D5A),
        block: Color(hex: 0xC0392B),
        warn: Color(hex: 0xC9871F),
        border: Color(hex: 0xE4DCCF)
    )

    /// The familiar Pi-hole red on warm near-black.
    static let piholeClassic = Theme(
        name: "pihole-classic",
        isDark: true,
        surface: Color(hex: 0x1A1213),
        panel: Color(hex: 0x241819),
        text: Color(hex: 0xF5E9E9),
        subtle: Color(hex: 0xA88B8B),
        accent: Color(hex: 0xE5322B),
        allow: Color(hex: 0x35C46A),
        block: Color(hex: 0xE5322B),
        warn: Color(hex: 0xF2B134),
        border: Color(hex: 0x4A2E30)
    )

    /// The rainbow easter-egg theme. Every token is a hue that rotates with
    /// `date`, so re-resolving it on a timer animates the whole app.
    static func party(at date: Date) -> Theme {
        let base = (date.timeIntervalSinceReferenceDate * 60)
            .truncatingRemainder(dividingBy: 360)

        func wild(
            _ offset: Double, saturation: Double = 1, brightness: Double = 1
        ) -> Color {
            let hue = (base + offset).truncatingRemainder(dividingBy: 360) / 360
            return Color(
                hue: hue, saturation: saturation, brightness: brightness)
        }

        return Theme(
            name: "party",
            isDark: true,
            surface: wild(0, saturation: 0.4, brightness: 0.08),
            panel: wild(210, saturation: 0.5, brightness: 0.14),
            text: wild(0),
            subtle: wild(60, saturation: 0.6, brightness: 0.75),
            accent: wild(90),
            allow: wild(150),
            block: wild(210),
            warn: wild(270),
            border: wild(330),
            ramp: (0..<7).map { wild(Double($0) * 360 / 7) }
        )
    }
}

/// The themes a person can pick.
enum ThemeName: String, CaseIterable, Identifiable {
    case auto
    case gloss
    case deepNight = "deep-night"
    case lightLuxury = "light-luxury"
    case piholeClassic = "pihole-classic"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .gloss: return "Gloss"
        case .deepNight: return "Deep Night"
        case .lightLuxury: return "Light Luxury"
        case .piholeClassic: return "Pi-hole Classic"
        }
    }

    var blurb: String {
        switch self {
        case .auto:
            return
                "Follows the system: Gloss in dark mode, Light Luxury in light."
        case .gloss: return "Signature hot-pink-to-cyan palette on deep void."
        case .deepNight:
            return "Calm midnight navy with a soft periwinkle accent."
        case .lightLuxury:
            return "Warm ivory paper with a disciplined brass accent."
        case .piholeClassic:
            return "The familiar Pi-hole red on warm near-black."
        }
    }

    /// The concrete theme for this choice. Only `auto` depends on the system
    /// appearance.
    func resolve(colorScheme: ColorScheme) -> Theme {
        switch self {
        case .auto: return colorScheme == .dark ? .gloss : .lightLuxury
        case .gloss: return .gloss
        case .deepNight: return .deepNight
        case .lightLuxury: return .lightLuxury
        case .piholeClassic: return .piholeClassic
        }
    }

    /// The appearance to force on the app, or nil to follow the system.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .lightLuxury: return .light
        case .gloss, .deepNight, .piholeClassic: return .dark
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.gloss
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
