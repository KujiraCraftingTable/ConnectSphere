import Foundation

/// Splits a `.sql` migration file into individual statements. postgres-nio only
/// speaks the extended query protocol (one command per message), so a file with
/// many statements has to be fed in pieces. This tracks the lexical state that
/// makes a naive `split(";")` wrong: single-/double-quoted strings, `$tag$…$tag$`
/// dollar-quoting (function bodies, `DO` blocks), `--` line comments and
/// `/* … */` block comments.
enum SQLScript {
    static func statements(_ sql: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(sql)
        var i = 0
        let n = chars.count

        enum State: Equatable {
            case normal
            case lineComment
            case blockComment
            case single          // '...'
            case double          // "..."
            case dollar(String)  // $tag$...$tag$
        }
        var state: State = .normal

        func peek(_ ahead: Int) -> Character? { i + ahead < n ? chars[i + ahead] : nil }

        while i < n {
            let c = chars[i]
            switch state {
            case .normal:
                if c == "-", peek(1) == "-" {
                    state = .lineComment; current.append(c); i += 1; continue
                }
                if c == "/", peek(1) == "*" {
                    state = .blockComment; current.append(c); i += 1; continue
                }
                if c == "'" { state = .single; current.append(c); i += 1; continue }
                if c == "\"" { state = .double; current.append(c); i += 1; continue }
                if c == "$" {
                    // Try to read a dollar-quote tag: $ [A-Za-z_0-9]* $
                    var j = i + 1
                    var tag = ""
                    while j < n, chars[j] != "$", chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                        tag.append(chars[j]); j += 1
                    }
                    if j < n, chars[j] == "$" {
                        let opener = "$\(tag)$"
                        state = .dollar(opener)
                        current += opener
                        i = j + 1
                        continue
                    }
                }
                if c == ";" {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { out.append(trimmed) }
                    current = ""
                    i += 1
                    continue
                }
                current.append(c); i += 1

            case .lineComment:
                current.append(c)
                if c == "\n" { state = .normal }
                i += 1

            case .blockComment:
                current.append(c)
                if c == "*", peek(1) == "/" { current.append("/"); i += 2; state = .normal; continue }
                i += 1

            case .single:
                current.append(c)
                if c == "'" { state = (peek(1) == "'" ? .single : .normal); if peek(1) == "'" { current.append("'"); i += 1 } }
                i += 1

            case .double:
                current.append(c)
                if c == "\"" { state = .normal }
                i += 1

            case .dollar(let opener):
                if c == "$" {
                    // Check if `opener` starts here.
                    let tagChars = Array(opener)
                    if i + tagChars.count <= n, Array(chars[i..<i+tagChars.count]) == tagChars {
                        current += opener
                        i += tagChars.count
                        state = .normal
                        continue
                    }
                }
                current.append(c); i += 1
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
