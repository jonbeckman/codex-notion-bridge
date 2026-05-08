import Foundation

public enum TriggerFilter {
    public static func matchedPrefix(in text: String, prefixes: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixes.first { prefix in
            trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    public static func instructionText(from text: String, prefixes: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = matchedPrefix(in: trimmed, prefixes: prefixes) else {
            return trimmed
        }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
