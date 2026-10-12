import Foundation

/// Reads snippets exported from other apps: Raycast (JSON), Espanso (YAML),
/// TextExpander and generic CSV. Placeholders are translated to Keystivo's
/// where an equivalent exists (`{clipboard}`, `{cursor}`, `{date:FORMAT}`…).
nonisolated public enum SnippetImporter {
    public enum Failure: Error, Equatable { case unrecognized }

    public static func parse(_ data: Data, fileName: String) throws -> [Snippet] {
        let text = String(decoding: data, as: UTF8.self)
        let ext = (fileName as NSString).pathExtension.lowercased()
        let snippets: [Snippet]
        switch ext {
        case "json": snippets = try raycast(data)
        case "yml", "yaml": snippets = espanso(text)
        case "csv", "txt": snippets = csv(text)
        default:
            if let parsed = try? raycast(data) { snippets = parsed } else if text.contains("trigger:") { snippets = espanso(text) } else { snippets = csv(text) }
        }
        guard !snippets.isEmpty else { throw Failure.unrecognized }
        return snippets
    }

    // MARK: Raycast

    private struct RaycastSnippet: Decodable {
        let name: String?
        let text: String
        let keyword: String?
    }

    static func raycast(_ data: Data) throws -> [Snippet] {
        let items = try JSONDecoder().decode([RaycastSnippet].self, from: data)
        return items.map { item in
            Snippet(name: item.name ?? String(item.text.prefix(30)), keyword: item.keyword ?? "", content: raycastPlaceholders(item.text), collection: "Raycast")
        }
    }

    /// `{date format="yyyy-MM-dd"}` → `{date:yyyy-MM-dd}`, `{time}` stays, `{clipboard offset=1}` → `{clipboard}`.
    static func raycastPlaceholders(_ text: String) -> String {
        var result = text
        let formatted = /\{(date|time|datetime)\s+format="([^"]*)"[^}]*\}/
        result = result.replacing(formatted) { match in "{date:\(match.2)}" }
        result = result.replacing(/\{clipboard[^}]*\}/) { _ in "{clipboard}" }
        result = result.replacing(/\{cursor[^}]*\}/) { _ in "{cursor}" }
        return result
    }

    // MARK: Espanso

    /// A small reader for Espanso match files: `- trigger:` / `replace:` pairs,
    /// quoted or block (`|`) values. Other keys are ignored.
    static func espanso(_ text: String) -> [Snippet] {
        var snippets: [Snippet] = []
        var trigger: String?
        var replace: String?
        var label: String?
        var blockIndent: Int?
        var blockLines: [String] = []

        func flushBlock() {
            if blockIndent != nil { replace = blockLines.joined(separator: "\n") }
            blockIndent = nil
            blockLines = []
        }
        func flushMatch() {
            flushBlock()
            if let trigger, let replace {
                let content = replace.replacingOccurrences(of: "{{clipboard}}", with: "{clipboard}")
                    .replacingOccurrences(of: "$|$", with: "{cursor}")
                snippets.append(Snippet(name: label ?? trigger, keyword: trigger, content: content, collection: "Espanso"))
            }
            trigger = nil
            replace = nil
            label = nil
        }

        for line in text.components(separatedBy: .newlines) {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let blockIndent {
                if trimmed.isEmpty || indent >= blockIndent {
                    blockLines.append(trimmed.isEmpty ? "" : String(line.dropFirst(blockIndent)))
                    continue
                }
                flushBlock()
            }
            var entry = trimmed
            if entry.hasPrefix("- ") {
                flushMatch()
                entry = String(entry.dropFirst(2))
            }
            guard let colon = entry.firstIndex(of: ":") else { continue }
            let key = entry[..<colon].trimmingCharacters(in: .whitespaces)
            let value = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "trigger": trigger = unquote(value)
            case "label": label = unquote(value)
            case "replace":
                if value == "|" || value == ">" || value == "|-" || value == ">-" {
                    blockIndent = indent + 2 + (trimmed.hasPrefix("- ") ? 2 : 0)
                } else {
                    replace = unquote(value)
                }
            default: break
            }
        }
        flushMatch()
        // Trim the trailing blank line block scalars keep.
        return snippets.map { snippet in
            var copy = snippet
            while copy.content.hasSuffix("\n") { copy.content.removeLast() }
            return copy
        }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") : inner
    }

    // MARK: CSV

    /// Columns by header (name/label, keyword/abbreviation/trigger, content/snippet/text/phrase),
    /// or without a header: keyword, content[, name].
    static func csv(_ text: String) -> [Snippet] {
        var rows = csvRows(text)
        guard let first = rows.first else { return [] }
        let header = first.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let names = ["name", "label", "title"], keywords = ["keyword", "abbreviation", "trigger", "shortcut"], contents = ["content", "snippet", "text", "phrase", "expansion", "replace"]
        var nameIndex: Int?, keywordIndex = 0, contentIndex = 1
        if let keyword = header.firstIndex(where: keywords.contains), let content = header.firstIndex(where: contents.contains) {
            keywordIndex = keyword
            contentIndex = content
            nameIndex = header.firstIndex(where: names.contains)
            rows.removeFirst()
        } else if first.count >= 3 {
            nameIndex = 2
        }
        return rows.compactMap { row in
            guard row.indices.contains(contentIndex), !row[contentIndex].isEmpty else { return nil }
            let keyword = row.indices.contains(keywordIndex) ? row[keywordIndex] : ""
            let name = nameIndex.flatMap { row.indices.contains($0) ? row[$0] : nil }.flatMap { $0.isEmpty ? nil : $0 }
            return Snippet(name: name ?? (keyword.isEmpty ? String(row[contentIndex].prefix(30)) : keyword), keyword: keyword, content: row[contentIndex], collection: "CSV")
        }
    }

    /// RFC 4180-style rows (quoted fields, doubled quotes, newlines inside quotes).
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            inQuotes = false
                            if next == "," { row.append(field); field = "" } else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" } else { field.append(next) }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty: inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }
}
