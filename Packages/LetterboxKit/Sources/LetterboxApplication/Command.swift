import Foundation

/// What a line typed into the composer means.
public enum ComposerInput: Equatable, Sendable {
    case text(String)
    case nick(String)
    case directMessage(to: String, text: String)
    case who
    case clear
    case help
    case unknown(String)
    case empty

    public static let helpText = """
    /nick <name>       change your nickname
    /msg <name> <text> private message someone nearby
    /who               list people nearby
    /clear             clear this conversation
    /help              show this help
    """

    public static func parse(_ raw: String) -> ComposerInput {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .empty }
        guard line.hasPrefix("/") else { return .text(line) }

        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        switch parts[0].lowercased() {
        case "/nick":
            let name = parts.dropFirst().joined(separator: " ")
            return name.isEmpty ? .unknown(line) : .nick(name)
        case "/msg", "/m":
            guard parts.count == 3 else { return .unknown(line) }
            let name = parts[1].hasPrefix("@") ? String(parts[1].dropFirst()) : parts[1]
            // maxSplits keeps any extra spaces after the name at the start of the text.
            return .directMessage(to: name, text: parts[2].trimmingCharacters(in: .whitespaces))
        case "/who", "/w":
            return .who
        case "/clear":
            return .clear
        case "/help", "/?":
            return .help
        default:
            return .unknown(parts[0])
        }
    }
}
