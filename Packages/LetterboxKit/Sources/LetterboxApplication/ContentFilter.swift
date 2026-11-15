import Foundation

/// On-device filter for offensive words in messages from other people (App Review
/// guideline 1.2 asks chat apps to filter objectionable material). Nothing is sent
/// anywhere: matching words are masked on this phone, and the user can turn it off.
///
/// Matching is per word, after folding case, accents, common letter swaps (`@` for `a`,
/// `0` for `o`) and stretched letters ("fuuuck"), so ordinary words that merely contain
/// a bad word ("Scunthorpe", "assessment") are left alone.
public enum ContentFilter {
    /// Masks each offensive word, keeping its first letter: "f***". Returns the text
    /// unchanged if there's nothing to mask.
    public static func mask(_ text: String) -> String {
        var result = ""
        var word = ""
        func flush() {
            if !word.isEmpty {
                result += isOffensive(word) ? masked(word) : word
                word = ""
            }
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            // "!" counts as a letter only inside a word ("b!tch"), not after one ("shit!").
            let insideWord = character == "!" && !word.isEmpty && index + 1 < characters.count && characters[index + 1].isLetter
            if character.isLetter || character.isNumber || "@$*".contains(character) || insideWord {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    public static func containsOffensiveWords(_ text: String) -> Bool {
        mask(text) != text
    }

    static func isOffensive(_ word: String) -> Bool {
        let plain = normalize(word, collapsing: false)
        guard plain.count >= 3 else { return false }
        if exact.contains(plain) || roots.contains(where: plain.hasPrefix) { return true }
        // Stretched letters ("fuuuck"): compare with every run collapsed, but only
        // against entries still long enough to be unambiguous ("ass" would become "as").
        let squeezed = normalize(word, collapsing: true)
        return squeezedExact.contains(squeezed) || squeezedRoots.contains(where: squeezed.hasPrefix)
    }

    private static func masked(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first) + String(repeating: "*", count: max(word.count - 1, 2))
    }

    /// Lowercase, no accents, letter swaps undone, and optionally every run of the same
    /// letter collapsed to one.
    static func normalize(_ word: String, collapsing: Bool) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let swaps: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"]
        var out = ""
        for character in folded {
            let letter = swaps[character] ?? character
            guard letter.isLetter else { continue }
            if collapsing, out.last == letter { continue }
            out.append(letter)
        }
        return out
    }

    private static func squeeze(_ entry: String) -> String { normalize(entry, collapsing: true) }

    // Kept short and conservative on purpose: words that are offensive in almost any
    // context, in plain spelling.
    /// Matched as a whole word.
    private static let exact: Set<String> = [
        "ass", "asshole", "assholes", "bastard", "bastards", "bitch", "bitches", "bitchy",
        "bollocks", "cock", "cocks", "cunt", "cunts", "dick", "dicks", "dickhead",
        "fag", "fags", "faggot", "faggots", "fuk", "nigga", "niggas", "nigger", "niggers",
        "pussy", "retard", "retards", "slut", "sluts", "twat", "twats", "whore", "whores",
        "wanker", "wankers", "chink", "chinks", "spic", "spics", "kike", "kikes",
        "tranny", "trannies", "shit", "shits", "bullshit",
    ]

    /// Matched at the start of a word ("fucking", "shitty"). Only roots that don't begin
    /// ordinary words: not "nigg" (niggle) or "fuk" (Fukushima).
    private static let roots: [String] = [
        "fuck", "motherfuck", "shit", "cunt", "faggot", "bitch", "whore", "wank",
    ]

    private static let squeezedExact = Set(exact.map(squeeze).filter { $0.count >= 4 })
    /// Not "shit": squeezed, "shiitake" starts with it.
    private static let squeezedRoots = roots.filter { $0 != "shit" }.map(squeeze).filter { $0.count >= 4 }
}
