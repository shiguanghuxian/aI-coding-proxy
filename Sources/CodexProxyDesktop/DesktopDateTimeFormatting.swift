#if os(macOS)
import Foundation

@MainActor
enum DesktopDateTimeFormat {
    static let pattern = "yyyy-MM-dd HH:mm:ss"
    static let compactPattern = "MM-dd HH:mm"

    static func string(from date: Date) -> String {
        self.formatter.string(from: date)
    }

    static func string(fromUnixSeconds seconds: Int64) -> String {
        self.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func compactString(fromUnixSeconds seconds: Int64) -> String {
        self.compactFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return self.formatter.date(from: trimmed)
    }

    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = Self.pattern
        formatter.isLenient = false
        return formatter
    }

    private static let formatter = DesktopDateTimeFormat.makeFormatter()
    private static let compactFormatter = {
        let formatter = DesktopDateTimeFormat.makeFormatter()
        formatter.dateFormat = DesktopDateTimeFormat.compactPattern
        return formatter
    }()
}

struct FixedDateTimeFieldCommitResult: Equatable {
    let text: String
    let acceptedDate: Date?
}

@MainActor
enum FixedDateTimeFieldLogic {
    static func displayText(for date: Date) -> String {
        DesktopDateTimeFormat.string(from: date)
    }

    static func commit(draft: String, currentValue: Date) -> FixedDateTimeFieldCommitResult {
        let canonicalCurrentText = self.displayText(for: currentValue)
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDraft.isEmpty else {
            return FixedDateTimeFieldCommitResult(text: canonicalCurrentText, acceptedDate: nil)
        }

        guard trimmedDraft != canonicalCurrentText else {
            return FixedDateTimeFieldCommitResult(text: canonicalCurrentText, acceptedDate: nil)
        }

        guard let parsedDate = DesktopDateTimeFormat.date(from: trimmedDraft) else {
            return FixedDateTimeFieldCommitResult(text: canonicalCurrentText, acceptedDate: nil)
        }

        let acceptedText = self.displayText(for: parsedDate)
        if acceptedText == canonicalCurrentText {
            return FixedDateTimeFieldCommitResult(text: canonicalCurrentText, acceptedDate: nil)
        }

        return FixedDateTimeFieldCommitResult(text: acceptedText, acceptedDate: parsedDate)
    }
}
#endif
