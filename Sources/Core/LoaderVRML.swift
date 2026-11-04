import Foundation

/// VRML 1.0 / 2.0 (.wrl) and X3D XML (.x3d). Handles indexed face/triangle sets
/// inside the transform hierarchy, plus DEF/USE. Primitive shapes (Box, Sphere...)
/// are ignored; exported meshes don't use them.
public enum LoaderVRML {

    final class Node {
        let type: String
        var fields: [String: Value] = [:]
        var children: [Node] = []   // anonymous children (VRML 1.0 groups, X3D child elements)
        init(type: String) { self.type = type }

        func nodes(_ field: String) -> [Node] {
            if case .nodes(let n)? = fields[field] { return n }
            return []
        }
        func numbers(_ field: String) -> [Double] {
            if case .numbers(let v)? = fields[field] { return v }
            return []
        }
        /// A node referenced by `field` (VRML) or a child element of one of `types` (X3D).
        func subnode(_ field: String, types: [String]) -> Node? {
            nodes(field).first ?? children.first { types.contains($0.type) }
        }
    }

    enum Value { case nodes([Node]), numbers([Double]), word(String) }

    // MARK: - VRML text parser

    struct Tokenizer {
        let b: TextBuffer
        var p = 0
        init(_ data: Data) { b = TextBuffer(data) }

        enum Tok: Equatable { case open, close, lbracket, rbracket, word(String), number(Double), string, eof }

        mutating func next() -> Tok {
            let n = b.count
            while p < n {
                let c = b[p]
                if c == 35 { b.skipToNextLine(&p); continue }                         // #
                if c == 32 || c == 9 || c == 10 || c == 13 || c == 44 { p += 1; continue } // whitespace / comma
                break
            }
            guard p < n else { return .eof }
            let c = b[p]
            switch c {
            case 123: p += 1; return .open
            case 125: p += 1; return .close
            case 91: p += 1; return .lbracket
            case 93: p += 1; return .rbracket
            case 34:
                p += 1
                while p < n && b[p] != 34 { if b[p] == 92 { p += 1 }; p += 1 }
                p += 1
                return .string
            default:
                if (c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46 {
                    var e = p
                    if let v = b.parseDouble(at: p, end: &e), e > p { p = e; return .number(v) }
                }
                let s = p
                while p < n {
                    let ch = b[p]
                    if ch <= 32 || ch == 123 || ch == 125 || ch == 91 || ch == 93 || ch == 44 || ch == 35 || ch == 34 { break }
                    p += 1
                }
                if p == s { p += 1; return next() }
                return .word(b.string(s, p))
            }
        }

        mutating func peek() -> Tok { let save = p; let t = next(); p = save; return t }
        mutating func peek2() -> Tok { let save = p; _ = next(); let t = next(); p = save; return t }
    }

    final class TextParser {
        var t: Tokenizer
        var defs: [String: Node] = [:]
        init(_ data: Data) { t = Tokenizer(data) }

        func parseFile() -> [Node] {
            var out: [Node] = []
            while true {
                let tok = t.peek()
                if tok == .eof { break }
                if case .word(let w) = tok {
                    if w == "ROUTE" { _ = t.next(); _ = t.next(); _ = t.next(); _ = t.next(); continue } // ROUTE a.b TO c.d
                    if w == "PROTO" || w == "EXTERNPROTO" { skipProto(); continue }
                    if let n = parseNode() { out.append(n) }
                    continue
                }
                _ = t.next()
            }
            return out
        }

        func skipProto() {
            _ = t.next() // PROTO
            _ = t.next() // name
            skipBalanced() // [ interface ]
            if t.peek() == .open { skipBalanced() } // { body } (EXTERNPROTO has a URL instead)
        }

        func skipBalanced() {
            var depth = 0
            repeat {
                let tok = t.next()
                if tok == .open || tok == .lbracket { depth += 1 }
                else if tok == .close || tok == .rbracket { depth -= 1 }
                else if tok == .eof { return }
            } while depth > 0
        }

        /// Parses `[DEF name] Type { ... }` or `USE name`.
        func parseNode() -> Node? {
            guard case .word(var w) = t.next() else { return nil }
            var defName: String? = nil
            if w == "USE" {
                if case .word(let name) = t.next() { return defs[name] }
                return nil
            }
            if w == "DEF" {
                if case .word(let name) = t.next() { defName = name }
                guard case .word(let ty) = t.next() else { return nil }
                w = ty
            }
            if w == "NULL" { return nil }
            guard t.peek() == .open else { return nil }
            _ = t.next()
            let node = Node(type: w)
            if let d = defName { defs[d] = node }
            while true {
                let tok = t.peek()
                if tok == .close { _ = t.next(); break }
                if tok == .eof { break }
                guard case .word(let field) = tok else { _ = t.next(); continue }
                // anonymous child node (VRML 1.0): Word {
                if t.peek2() == .open || field == "DEF" || field == "USE" {
                    if let c = parseNode() { node.children.append(c) }
                    continue
                }
                _ = t.next()
                if field == "ROUTE" { _ = t.next(); _ = t.next(); _ = t.next(); continue }
                node.fields[field] = parseValue()
            }
            return node
        }

        func parseValue() -> Value {
            let tok = t.peek()
            switch tok {
            case .lbracket:
                _ = t.next()
                var nums: [Double] = []
                var nodes: [Node] = []
                while true {
                    let x = t.peek()
                    if x == .rbracket { _ = t.next(); break }
                    if x == .eof { break }
                    switch x {
                    case .number(let v): _ = t.next(); nums.append(v)
                    case .word:
                        if t.peek2() == .open || x == .word("DEF") || x == .word("USE") {
                            if let n = parseNode() { nodes.append(n) }
                        } else { _ = t.next() }
                    default: _ = t.next()
                    }
                }
                return nodes.isEmpty ? .numbers(nums) : .nodes(nodes)
            case .number:
                var nums: [Double] = []
                while case .number(let v) = t.peek() { _ = t.next(); nums.append(v) }
                return .numbers(nums)
            case .word(let w):
                if w == "DEF" || w == "USE" || t.peek2() == .open {
                    if let n = parseNode() { return .nodes([n]) }
                    return .nodes([])
                }
                _ = t.next()
                return .word(w)
            default:
                _ = t.next()
                return .word("")
            }
        }
    }

    public static func loadVRML(_ data: Data) throws -> Mesh {
        let header = String(decoding: data.prefix(16), as: UTF8.self)
        let isV1 = header.contains("V1.0")
        let parser = TextParser(data)
        let roots = parser.parseFile()
        var out = Mesh()
        if isV1 {
            var state = V1State()
            for n in roots { walkV1(n, &state, &out, 0) }
        } else {
            for n in roots { walk(n, .identity, &out, 0) }
        }
        return try finish(out)
    }

    // MARK: - X3D

    public static func loadX3D(_ data: Data) throws -> Mesh {
        guard let root = XMLNode.parse(data) else { throw ModelError.malformed("x3d") }
        var defs: [String: Node] = [:]
        func convert(_ x: XMLNode) -> Node? {
            if let use = x.attributes["USE"] { return defs[use] }
            let n = Node(type: x.name)
            if let d = x.attributes["DEF"] { defs[d] = n }
            for (k, v) in x.attributes where k != "DEF" && k != "containerField" {
                let nums = XMLNode.numbers(v)
                n.fields[k] = nums.isEmpty ? .word(v) : .numbers(nums)
            }
            for c in x.children { if let cn = convert(c) { n.children.append(cn) } }
            return n
        }
        guard let scene = root.first("Scene"), let s = convert(scene) else { throw ModelError.malformed("x3d: no Scene") }
        var out = Mesh()
        walk(s, .identity, &out, 0)
        return try finish(out)
    }

    static func finish(_ m: Mesh) throws -> Mesh {
        var out = m
        if out.isEmpty || out.indices.isEmpty { throw ModelError.empty }
        out.sanitize()
        out.convertYUpToZUp()
        return out
    }

    // MARK: - VRML 2 / X3D scene walk

    static let groupTypes: Set<String> = ["Transform", "Group", "Anchor", "Billboard", "Collision", "Scene",
                                          "StaticGroup", "Inline", "CADAssembly", "CADPart", "CADLayer", "CADFace"]

    static func walk(_ n: Node, _ parent: Transform, _ out: inout Mesh, _ depth: Int) {
        guard depth < 128 else { return }
        var world = parent
        if n.type == "Transform" || n.type == "CADPart" {
            world = transformOf(n).then(parent)
        }
        switch n.type {
        case "Shape":
            if let g = n.subnode("geometry", types: ["IndexedFaceSet", "IndexedTriangleSet", "TriangleSet"]) {
                out.append(geometry(g), transform: world)
            }
            return
        case "Switch":
            let choice = Int(n.numbers("whichChoice").first ?? -1)
            let kids = n.nodes("choice") + n.nodes("children") + n.children
            if choice >= 0 && choice < kids.count { walk(kids[choice], world, &out, depth + 1) }
            return
        case "LOD":
            let kids = n.nodes("level") + n.nodes("children") + n.children
            if let first = kids.first { walk(first, world, &out, depth + 1) }
            return
        default: break
        }
        for c in n.nodes("children") + n.children { walk(c, world, &out, depth + 1) }
    }

    static func transformOf(_ n: Node) -> Transform {
        let t = n.numbers("translation"), r = n.numbers("rotation"), s = n.numbers("scale"), c = n.numbers("center")
        let tr = t.count == 3 ? t : [0, 0, 0]
        let ce = c.count == 3 ? c : [0, 0, 0]
        let q = r.count == 4 ? LoaderDAE.axisAngleQuat(r[0], r[1], r[2], r[3]) : nil
        // T * C * R * S * -C
        let minusC = Transform.fromTRS(t: [-ce[0], -ce[1], -ce[2]], r: nil, s: nil)
        let rs = Transform.fromTRS(t: nil, r: q, s: s.count == 3 ? s : nil)
        let tc = Transform.fromTRS(t: [tr[0] + ce[0], tr[1] + ce[1], tr[2] + ce[2]], r: nil, s: nil)
        return minusC.then(rs).then(tc)
    }

    static func geometry(_ g: Node) -> Mesh {
        var m = Mesh()
        let coord = g.subnode("coord", types: ["Coordinate", "CoordinateDouble"])
        let pts = coord?.numbers("point") ?? []
        var i = 0
        while i + 2 < pts.count { m.addVertex(Float(pts[i]), Float(pts[i + 1]), Float(pts[i + 2])); i += 3 }
        let n = m.vertexCount
        func tri(_ a: Int, _ b: Int, _ c: Int) {
            if a >= 0, b >= 0, c >= 0, a < n, b < n, c < n { m.addTriangle(UInt32(a), UInt32(b), UInt32(c)) }
        }
        switch g.type {
        case "IndexedFaceSet":
            var poly: [Int] = []
            for v in g.numbers("coordIndex") + [-1] {
                let k = Int(v)
                if k < 0 {
                    if poly.count >= 3 { for j in 1..<(poly.count - 1) { tri(poly[0], poly[j], poly[j + 1]) } }
                    poly.removeAll(keepingCapacity: true)
                } else { poly.append(k) }
            }
        case "IndexedTriangleSet":
            let idx = g.numbers("index").map { Int($0) }
            var j = 0
            while j + 2 < idx.count { tri(idx[j], idx[j + 1], idx[j + 2]); j += 3 }
        case "TriangleSet":
            var j = 0
            while j + 2 < n { tri(j, j + 1, j + 2); j += 3 }
        default: break
        }
        return m
    }

    // MARK: - VRML 1.0 (stateful)

    struct V1State {
        var coords: [Float] = []
        var transform = Transform.identity
    }

    static func walkV1(_ n: Node, _ st: inout V1State, _ out: inout Mesh, _ depth: Int) {
        guard depth < 128 else { return }
        switch n.type {
        case "Separator", "TransformSeparator":
            var inner = st
            for c in n.children { walkV1(c, &inner, &out, depth + 1) }
            if n.type == "TransformSeparator" { st.coords = inner.coords }
        case "Group", "WWWAnchor", "LOD", "Switch":
            for c in n.children { walkV1(c, &st, &out, depth + 1) }
        case "Coordinate3":
            st.coords = n.numbers("point").map { Float($0) }
        case "Translation":
            let t = n.numbers("translation")
            if t.count == 3 { st.transform = Transform.fromTRS(t: t, r: nil, s: nil).then(st.transform) }
        case "Rotation":
            let r = n.numbers("rotation")
            if r.count == 4 { st.transform = Transform.fromTRS(t: nil, r: LoaderDAE.axisAngleQuat(r[0], r[1], r[2], r[3]), s: nil).then(st.transform) }
        case "Scale":
            let s = n.numbers("scaleFactor")
            if s.count == 3 { st.transform = Transform.fromTRS(t: nil, r: nil, s: s).then(st.transform) }
        case "Transform":
            let t = n.numbers("translation"), r = n.numbers("rotation"), s = n.numbers("scaleFactor")
            let local = Transform.fromTRS(t: t.count == 3 ? t : nil,
                                          r: r.count == 4 ? LoaderDAE.axisAngleQuat(r[0], r[1], r[2], r[3]) : nil,
                                          s: s.count == 3 ? s : nil)
            st.transform = local.then(st.transform)
        case "MatrixTransform":
            let v = n.numbers("matrix")
            if v.count == 16 {
                let m = Transform(m: [Float(v[0]), Float(v[1]), Float(v[2]), Float(v[4]), Float(v[5]), Float(v[6]),
                                      Float(v[8]), Float(v[9]), Float(v[10]), Float(v[12]), Float(v[13]), Float(v[14])])
                st.transform = m.then(st.transform)
            }
        case "IndexedFaceSet":
            var m = Mesh()
            m.positions = st.coords
            let cnt = m.vertexCount
            var poly: [Int] = []
            for v in n.numbers("coordIndex") + [-1] {
                let k = Int(v)
                if k < 0 {
                    if poly.count >= 3 {
                        for j in 1..<(poly.count - 1) where poly[0] < cnt && poly[j] < cnt && poly[j + 1] < cnt {
                            m.addTriangle(UInt32(poly[0]), UInt32(poly[j]), UInt32(poly[j + 1]))
                        }
                    }
                    poly.removeAll(keepingCapacity: true)
                } else { poly.append(k) }
            }
            if !m.indices.isEmpty { out.append(m, transform: st.transform) }
        default:
            break
        }
    }
}
