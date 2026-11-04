import Foundation

/// Small DOM built on XMLScanner, for formats with modest XML (Collada, X3D, E57 headers).
public final class XMLNode {
    public let name: String
    public var attributes: [String: String] = [:]
    public var children: [XMLNode] = []
    public var text = ""
    public weak var parent: XMLNode?

    init(name: String) { self.name = name }

    public static func parse(_ data: Data) -> XMLNode? {
        var s = XMLScanner(TextBuffer(data))
        let root = XMLNode(name: "#document")
        var stack: [XMLNode] = [root]
        var textParts: [ObjectIdentifier: [String]] = [:]
        loop: while true {
            switch s.next() {
            case .eof: break loop
            case .start:
                let n = XMLNode(name: s.name)
                n.attributes = s.allAttributes()
                n.parent = stack.last
                stack.last!.children.append(n)
                if !s.selfClosing { stack.append(n) }
            case .end:
                if stack.count > 1 {
                    let n = stack.removeLast()
                    if let parts = textParts.removeValue(forKey: ObjectIdentifier(n)) { n.text = parts.joined() }
                }
            case .text:
                if let cur = stack.last { textParts[ObjectIdentifier(cur), default: []].append(s.text) }
            }
        }
        return root.children.first
    }

    public func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// Depth-first search.
    public func descendants(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        func walk(_ n: XMLNode) { for c in n.children { if c.name == name { out.append(c) }; walk(c) } }
        walk(self)
        return out
    }

    public func first(_ name: String) -> XMLNode? {
        for c in children {
            if c.name == name { return c }
            if let f = c.first(name) { return f }
        }
        return nil
    }

    /// Parses whitespace/comma separated numbers from a string.
    public static func numbers(_ s: String) -> [Double] {
        let buf = TextBuffer(bytes: Array(s.utf8))
        var out: [Double] = []
        out.reserveCapacity(s.utf8.count / 6)
        var p = 0, end = 0
        while p < buf.count {
            let c = buf[p]
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 44 { p += 1; continue }
            if let v = buf.parseDouble(at: p, end: &end) { out.append(v); p = end } else { p += 1 }
        }
        return out
    }

    public var numbers: [Double] { XMLNode.numbers(text) }
}

extension XMLScanner {
    /// All attributes of the current tag (local names, prefixes stripped).
    public func allAttributes() -> [String: String] {
        var out: [String: String] = [:]
        let b = buf
        var p = attrStart
        while p < attrEnd {
            while p < attrEnd && (b[p] == 32 || b[p] == 9 || b[p] == 10 || b[p] == 13) { p += 1 }
            let ns = p
            while p < attrEnd && b[p] != 61 && b[p] != 32 && b[p] != 9 && b[p] != 10 && b[p] != 13 { p += 1 }
            let ne = p
            while p < attrEnd && b[p] != 34 && b[p] != 39 { p += 1 }
            guard p < attrEnd else { break }
            let q = b[p]; p += 1
            let vs = p
            while p < attrEnd && b[p] != q { p += 1 }
            let ve = p
            p += 1
            var ls = ns
            var i = ns
            while i < ne { if b[i] == 58 { ls = i + 1 }; i += 1 }
            if ne > ls { out[b.string(ls, ne)] = XMLScanner.unescape(b.string(vs, ve)) }
        }
        return out
    }
}
