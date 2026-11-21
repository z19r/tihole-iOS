import Foundation
import PiholeKit

/// Display formatting shared by every screen. Pure functions, so they are
/// covered by unit tests on the host without a simulator.
public enum Format {
    /// Thousands-separated integer: 1234567 -> "1,234,567".
    public static func count(_ value: Int) -> String {
        let negative = value < 0
        let digits = String(value.magnitude)
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 {
                out.append(",")
            }
            out.append(character)
        }
        return negative ? "-" + out : out
    }

    /// One-decimal percentage: 12.345 -> "12.3%".
    public static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Compact uptime: "3d 4h", "2h 15m", "9m". Under a minute is "0m".
    public static func uptime(seconds: Int64) -> String {
        if seconds < 60 {
            return "0m"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Kibibytes as a short human figure: "512K", "128M", "3.7G".
    public static func kibibytes(_ kib: Int64) -> String {
        let mib: Int64 = 1024
        let gib: Int64 = 1024 * 1024
        if kib >= gib {
            return String(format: "%.1fG", Double(kib) / Double(gib))
        }
        if kib >= mib {
            return String(format: "%.0fM", Double(kib) / Double(mib))
        }
        return "\(kib)K"
    }

    /// Memory gauge label: "41.2% · 1.5G/3.7G", or just the percentage when
    /// totals are unknown.
    public static func memory(_ system: SystemInfo) -> String {
        let percentage = String(format: "%.1f%%", system.memUsedPercent)
        if system.memTotalKiB > 0 {
            return
                """
                \(percentage) · \
                \(kibibytes(system.memUsedKiB))/\(kibibytes(system.memTotalKiB))
                """
        }
        return percentage
    }

    /// Clock-style countdown for the blocking pill: "4:05", "1:02:03".
    public static func countdown(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(pad2(minutes)):\(pad2(secs))"
        }
        return "\(minutes):\(pad2(secs))"
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// "1 issue" / "3 issues".
    public static func issues(_ count: Int) -> String {
        count == 1 ? "1 issue" : "\(count) issues"
    }

    /// Wall-clock time of a unix timestamp: "15:04:05".
    public static func clock(
        _ epochSeconds: Double, timeZone: TimeZone = .current
    ) -> String {
        if epochSeconds <= 0 {
            return "-"
        }
        return formatter("HH:mm:ss", timeZone).string(
            from: Date(timeIntervalSince1970: epochSeconds)
        )
    }

    /// Short date and time of a unix timestamp: "Jan 2 15:04".
    public static func shortDateTime(
        _ epochSeconds: Int64, timeZone: TimeZone = .current
    ) -> String {
        if epochSeconds <= 0 {
            return "-"
        }
        return formatter("MMM d HH:mm", timeZone).string(
            from: Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        )
    }

    private static func formatter(_ pattern: String, _ timeZone: TimeZone)
        -> DateFormatter
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// The trimmed string, or "-" when it is blank.
    public static func orDash(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "-" : value
    }
}

/// A semantic color role, resolved against the active theme by the UI.
public enum Tone: Sendable, Equatable {
    case allow
    case block
    case warn
    case neutral
}

public enum QueryStatus {
    /// Classifies an FTL query status string: blocked statuses (GRAVITY,
    /// DENYLIST, REGEX, anything containing BLOCK) are `.block`; answered
    /// ones (FORWARDED, CACHE, RETRIED) are `.allow`.
    public static func tone(_ status: String) -> Tone {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if value.isEmpty {
            return .neutral
        }
        if value.contains("BLOCK")
            || value.hasPrefix("GRAVITY")
            || value.hasPrefix("DENYLIST")
            || value.hasPrefix("REGEX")
            || value.hasPrefix("SPECIAL_DOMAIN")
        {
            return .block
        }
        if value.hasPrefix("FORWARD")
            || value.hasPrefix("CACHE")
            || value.hasPrefix("RETRIED")
            || value == "OK"
        {
            return .allow
        }
        return .neutral
    }
}

public enum ListStatus {
    /// Short label for a gravity list's integer status.
    public static func label(_ status: Int) -> String {
        switch status {
        case 1: return "ok"
        case 2: return "warn"
        case 3: return "error"
        default: return "unknown"
        }
    }

    public static func tone(_ status: Int) -> Tone {
        switch status {
        case 1: return .allow
        case 2: return .warn
        case 3: return .block
        default: return .neutral
        }
    }
}

public enum GroupIDs {
    /// Parses "0, 2,5" into [0, 2, 5], skipping blanks and non-numbers.
    public static func parse(_ csv: String) -> [Int] {
        csv.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Renders [0, 2] as "0, 2".
    public static func csv(_ groups: [Int]) -> String {
        groups.map { String($0) }.joined(separator: ", ")
    }
}

public enum ErrorText {
    /// True for errors that only mean "the task was cancelled" and should
    /// never be shown.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }

    /// A message fit for an inline banner.
    public static func describe(_ error: Error) -> String {
        if let piholeError = error as? PiholeError {
            return piholeError.errorDescription ?? "Request failed"
        }
        return error.localizedDescription
    }

    /// Like `describe`, but when FTL refused a destructive action it adds
    /// the setting that permits it.
    public static func describeDestructive(_ error: Error) -> String {
        let base = describe(error)
        guard let apiError = (error as? PiholeError)?.apiError else {
            return base
        }
        let haystack =
            (apiError.message + " " + apiError.key + " " + apiError.hint)
            .lowercased()
        if apiError.status == 403
            || haystack.contains("destructive")
            || haystack.contains("forbidden")
        {
            return base + " "
                + """
                Enable webserver.api.allow_destructive in the Pi-hole \
                config to permit this.
                """
        }
        return base
    }
}
