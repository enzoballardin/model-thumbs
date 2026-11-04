import Foundation

/// A tiny, fast, non-validating XML pull scanner. It is much faster than
/// Foundation's XMLParser for the huge vertex/triangle lists found in 3MF/AMF.
public struct XMLScanner {
    public enum Event {
        case start   // start tag (check `selfClosing`)
        case end     // end tag
        case text    // character data between tags (range in textStart..<textEnd)
        case eof
    }

    public let buf: TextBuffer
    public var pos = 0

    // Current tag info
    public private(set) var nameStart = 0
    public private(set) var nameEnd = 0
    public private(set) var attrStart = 0
    public private(set) var attrEnd = 0
    public private(set) var selfClosing = false
    public private(set) var textStart = 0
    public private(set) var textEnd = 0

    public init(_ buf: TextBuffer) { self.buf = buf }

    /// Local tag name (namespace prefix stripped) equals literal?
    @inline(__always)
    public func nameIs(_ literal: StaticString) -> Bool {
        var s = nameStart
        // strip prefix
        var i = nameStart
        while i < nameEnd { if buf[i] == 58 { s = i + 1 }; i += 1 } // ':'
        let n = literal.utf8CodeUnitCount
        guard nameEnd - s == n else { return false }
        return buf.matches(literal, at: s)
    }

    public var name: String {
        var s = nameStart
        var i = nameStart
        while i < nameEnd { if buf[i] == 58 { s = i + 1 }; i += 1 }
        return buf.string(s, nameEnd)
    }

    public mutating func next() -> Event {
        let b = buf
        let n = b.count
        while pos < n {
            if b[pos] != 60 { // '<' -> text
                let ts = pos
                while pos < n && b[pos] != 60 { pos += 1 }
                textStart = ts; textEnd = pos
                // skip pure whitespace text
                var allWS = true
                var k = ts
                while k < pos { let c = b[k]; if c != 32 && c != 9 && c != 10 && c != 13 { allWS = false; break }; k += 1 }
                if !allWS { return .text }
                continue
            }
            // at '<'
            let c1 = pos + 1 < n ? b[pos + 1] : 0
            if c1 == 33 { // '!' comment / CDATA / doctype
                if b.matches("<!--", at: pos) {
                    pos += 4
                    while pos + 2 < n && !(b[pos] == 45 && b[pos + 1] == 45 && b[pos + 2] == 62) { pos += 1 }
                    pos += 3
                } else if b.matches("<![CDATA[", at: pos) {
                    let ts = pos + 9
                    pos = ts
                    while pos + 2 < n && !(b[pos] == 93 && b[pos + 1] == 93 && b[pos + 2] == 62) { pos += 1 }
                    textStart = ts; textEnd = pos
                    pos += 3
                    return .text
                } else {
                    while pos < n && b[pos] != 62 { pos += 1 }
                    pos += 1
                }
                continue
            }
            if c1 == 63 { // '?' processing instruction
                while pos + 1 < n && !(b[pos] == 63 && b[pos + 1] == 62) { pos += 1 }
                pos += 2
                continue
            }
            let isEnd = c1 == 47 // '/'
            pos += isEnd ? 2 : 1
            nameStart = pos
            while pos < n {
                let c = b[pos]
                if c == 32 || c == 9 || c == 10 || c == 13 || c == 47 || c == 62 { break }
                pos += 1
            }
            nameEnd = pos
            attrStart = pos
            // find end of tag, respecting quotes
            var quote: UInt8 = 0
            while pos < n {
                let c = b[pos]
                if quote != 0 { if c == quote { quote = 0 } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { break }
                pos += 1
            }
            attrEnd = pos
            selfClosing = attrEnd > attrStart && b[attrEnd - 1] == 47
            if selfClosing { attrEnd -= 1 }
            pos += 1 // skip '>'
            return isEnd ? .end : .start
        }
        return .eof
    }

    /// Finds an attribute value range by local name (prefix ignored).
    public func attributeRange(_ literal: StaticString) -> (Int, Int)? {
        let b = buf
        var p = attrStart
        let n = literal.utf8CodeUnitCount
        while p < attrEnd {
            while p < attrEnd && (b[p] == 32 || b[p] == 9 || b[p] == 10 || b[p] == 13) { p += 1 }
            let ns = p
            while p < attrEnd && b[p] != 61 && b[p] != 32 { p += 1 } // '='
            let ne = p
            while p < attrEnd && b[p] != 34 && b[p] != 39 { p += 1 }
            guard p < attrEnd else { return nil }
            let q = b[p]; p += 1
            let vs = p
            while p < attrEnd && b[p] != q { p += 1 }
            let ve = p
            p += 1
            // local name
            var ls = ns
            var i = ns
            while i < ne { if b[i] == 58 { ls = i + 1 }; i += 1 }
            if ne - ls == n && b.matches(literal, at: ls) { return (vs, ve) }
        }
        return nil
    }

    /// Single pass over attributes whose (local) name is one or two characters long,
    /// e.g. x/y/z or v1/v2/v3. Calls `body(c0, c1, valueStart)` with c1 == 0 for one-char names.
    @inline(__always)
    public func forEachShortAttribute(_ body: (UInt8, UInt8, Int) -> Void) {
        let b = buf
        var p = attrStart
        while p < attrEnd {
            while p < attrEnd && (b[p] == 32 || b[p] == 9 || b[p] == 10 || b[p] == 13) { p += 1 }
            let ns = p
            while p < attrEnd && b[p] != 61 && b[p] != 32 { p += 1 }
            let ne = p
            while p < attrEnd && b[p] != 34 && b[p] != 39 { p += 1 }
            guard p < attrEnd else { return }
            let q = b[p]; p += 1
            let vs = p
            while p < attrEnd && b[p] != q { p += 1 }
            p += 1
            let len = ne - ns
            if len == 1 { body(b[ns], 0, vs) } else if len == 2 { body(b[ns], b[ns + 1], vs) }
        }
    }

    public func attribute(_ literal: StaticString) -> String? {
        guard let (s, e) = attributeRange(literal) else { return nil }
        return Self.unescape(buf.string(s, e))
    }

    @inline(__always)
    public func doubleAttribute(_ literal: StaticString) -> Double? {
        guard let (s, e) = attributeRange(literal) else { return nil }
        var end = s
        var p = s
        while p < e && (buf[p] == 32) { p += 1 }
        let v = buf.parseDouble(at: p, end: &end)
        return end <= e ? v : nil
    }

    @inline(__always)
    public func intAttribute(_ literal: StaticString) -> Int? {
        guard let (s, e) = attributeRange(literal) else { return nil }
        var end = s
        let v = buf.parseInt(at: s, end: &end)
        return end <= e ? v : nil
    }

    public var text: String { Self.unescape(buf.string(textStart, textEnd)) }

    public var textDouble: Double? {
        var p = textStart
        while p < textEnd, buf[p] == 32 || buf[p] == 9 || buf[p] == 10 || buf[p] == 13 { p += 1 }
        var end = p
        let v = buf.parseDouble(at: p, end: &end)
        return end <= textEnd ? v : nil
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
