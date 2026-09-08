import Foundation

/// Speech-only cleanup, mirrored by windows/speech_text.py. It never changes
/// displayed replies. Code already flattened by extraction cannot be identified
/// reliably; its ordinary content is preserved instead of guessing.
enum SpeechText {
    static let maximumInputBytes = 256 * 1024
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // These are fixed, locally maintained patterns, never user expressions.
        try! NSRegularExpression(pattern: pattern)
    }
    private static let fence = regex(#"^[ \t]{0,3}(`{3,}|~{3,})(.*)$"#)
    private static let link = regex(#"!?\[([^\[\]\r\n]*)\]\((?:<[^<>\r\n]*>|(?:[^()\r\n]|\([^()\r\n]*\))*)\)"#)
    private static let autolink = regex(#"(?i)<https?://[^<>\r\n]+>"#)
    private static let url = regex(#"(?i)(?<![A-Za-z0-9_])https?://[^\s<>\[\]{}"'，。！？；：、（）【】]+"#)
    private static let quotedPath = regex(#"(?:"(?:[A-Za-z]:[\\/]|/|\\\\)[^"\r\n]+"|'(?:[A-Za-z]:[\\/]|/|\\\\)[^'\r\n]+'|<(?:[A-Za-z]:[\\/]|/|\\\\)[^>\r\n]+>)"#)
    private static let windowsPath = regex(#"(?<![A-Za-z0-9_/:\\])(?:[A-Za-z]:[\\/]|\\\\[^\\/\s]+[\\/])[^\s<>\[\]{}"'，。！？；：、（）【】]+"#)
    // Unicode words include Chinese alternatives. A bare Unix path needs a
    // second component; ambiguous /name, denominators and math stay intact.
    private static let unixPath = regex(#"(?<![\w/:\\])/(?![-+−]?\d)(?![^\s<>\[\]{}"'，。！？；：、（）【】]*[=+*^|])(?=[^\s<>\[\]{}"'，。！？；：、（）【】]*/)[^\s<>\[\]{}"'，。！？；：、（）【】]+"#)
    private static let uuid = regex(#"(?<![A-Za-z0-9_])[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}(?![A-Za-z0-9_])"#)
    // A long decimal number alone is not sufficient evidence of a hash.
    private static let hash = regex(#"(?<![A-Za-z0-9_])(?:0x)?(?=[A-Fa-f0-9]*[A-Fa-f])[A-Fa-f0-9]{32,}(?![A-Za-z0-9_])"#)
    private static let heading = regex(#"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#)
    private static let inline = regex(#"`([^`\r\n]*)`"#)
    // Preserve adjacent ASCII exponent operands and ambiguous __dunder__ names.
    private static let bold = regex(#"(?<![A-Za-z0-9])(?:\*\*([^*\r\n]+)\*\*|__(?![A-Za-z0-9]+__)([^_\r\n]+)__)(?![A-Za-z0-9])"#)
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)")

    private static func replace(_ text: String, _ pattern: NSRegularExpression,
                                _ body: @escaping (NSTextCheckingResult, NSString) -> String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        // Append untouched spans once; do not repeatedly copy a shrinking body.
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += body(match, source)
            cursor = NSMaxRange(match.range)
        }
        result += source.substring(from: cursor)
        return result
    }
    private static func shortened(_ match: NSTextCheckingResult, _ source: NSString, _ word: String) -> String {
        let value = source.substring(with: match.range)
        var end = value.endIndex
        while end > value.startIndex {
            let before = value.index(before: end)
            guard value[before...].unicodeScalars.first.map(trailing.contains) == true else { break }
            end = before
        }
        return word + String(value[end...])
    }
    private static func withoutFences(_ text: String) -> String {
        var result: [String] = []
        var opened: String?
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let source = line as NSString
            let match = fence.firstMatch(in: line, range: NSRange(location: 0, length: source.length))
            let marker = match.map { source.substring(with: $0.range(at: 1)) }
            if let current = opened {
                if let match, let marker, marker.first == current.first, marker.count >= current.count,
                   source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces).isEmpty {
                    opened = nil
                }
                continue
            }
            if let marker { opened = marker; result.append("代码请在电脑查看。") }
            else { result.append(line) }
        }
        return result.joined(separator: "\n")
    }
    static func clean(_ text: String) -> String {
        // Normal reports are <=64 KiB. Keep malformed callers bounded, too.
        let prefix = Array(text.utf8.prefix(maximumInputBytes + 1))
        let overflow = prefix.count > maximumInputBytes
        var bytes = Array(prefix.prefix(maximumInputBytes))
        if overflow {
            // At most three removals find the previous complete UTF-8 scalar.
            while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        }
        var value = withoutFences(String(decoding: bytes, as: UTF8.self))
        value = replace(value, link) { $1.substring(with: $0.range(at: 1)) }
        value = replace(value, autolink) { _, _ in "链接" }
        value = replace(value, url) { shortened($0, $1, "链接") }
        value = replace(value, quotedPath) { _, _ in "文件路径" }
        value = replace(value, windowsPath) { shortened($0, $1, "文件路径") }
        value = replace(value, unixPath) { shortened($0, $1, "文件路径") }
        value = replace(value, uuid) { _, _ in "标识符" }
        value = replace(value, hash) { _, _ in "标识符" }
        value = replace(value, heading) { _, _ in "" }
        value = replace(value, inline) { $1.substring(with: $0.range(at: 1)) }
        value = replace(value, bold) { match, source in
            source.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
        }
        if overflow { value += "\n内容较长，剩余内容请查看电脑。" }
        return value
    }
}
