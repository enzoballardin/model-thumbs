import Foundation

/// Collada (.dae): geometries placed by the visual scene's node hierarchy.
public enum LoaderDAE {
    public static func load(_ data: Data) throws -> Mesh {
        guard let root = XMLNode.parse(data), root.name == "COLLADA" else { throw ModelError.malformed("not Collada") }

        // Index everything with an id
        var byID: [String: XMLNode] = [:]
        func index(_ n: XMLNode) { if let id = n.attributes["id"] { byID[id] = n }; n.children.forEach(index) }
        index(root)
        func ref(_ s: String?) -> XMLNode? {
            guard var s = s else { return nil }
            if s.hasPrefix("#") { s.removeFirst() }
            return byID[s]
        }

        var geomCache: [ObjectIdentifier: Mesh] = [:]
        func geometryMesh(_ g: XMLNode) -> Mesh {
            if let m = geomCache[ObjectIdentifier(g)] { return m }
            var out = Mesh()
            guard let mesh = g.child("mesh") else { geomCache[ObjectIdentifier(g)] = out; return out }

            // Positions: <vertices><input semantic="POSITION" source="#src"/>
            func sourcePositions(_ src: XMLNode?) -> [Float] {
                guard let src = src else { return [] }
                let stride = Int(src.first("accessor")?.attributes["stride"] ?? "3") ?? 3
                let vals = src.first("float_array")?.numbers ?? []
                var pos: [Float] = []
                pos.reserveCapacity(vals.count / max(stride, 1) * 3)
                var i = 0
                while i + 2 < vals.count { pos += [Float(vals[i]), Float(vals[i + 1]), Float(vals[i + 2])]; i += max(stride, 3) }
                return pos
            }
            var positionsFor: [String: [Float]] = [:]
            for v in mesh.children("vertices") {
                if let id = v.attributes["id"],
                   let inp = v.children("input").first(where: { $0.attributes["semantic"] == "POSITION" }) {
                    positionsFor[id] = sourcePositions(ref(inp.attributes["source"]))
                }
            }

            for prim in mesh.children where ["triangles", "polylist", "polygons", "trifans", "tristrips"].contains(prim.name) {
                let inputs = prim.children("input")
                guard let vin = inputs.first(where: { $0.attributes["semantic"] == "VERTEX" }) else { continue }
                var src = vin.attributes["source"] ?? ""
                if src.hasPrefix("#") { src.removeFirst() }
                let pos = positionsFor[src] ?? sourcePositions(byID[src])
                guard !pos.isEmpty else { continue }
                let vOff = Int(vin.attributes["offset"] ?? "0") ?? 0
                let stride = (inputs.compactMap { Int($0.attributes["offset"] ?? "0") }.max() ?? 0) + 1
                let base = UInt32(out.vertexCount)
                var sub = Mesh()
                sub.positions = pos
                let nverts = pos.count / 3

                func vertexIndices(_ p: [Double]) -> [Int] {
                    var out: [Int] = []
                    out.reserveCapacity(p.count / stride)
                    var i = vOff
                    while i < p.count { out.append(Int(p[i])); i += stride }
                    return out
                }
                func addPolygon(_ ids: ArraySlice<Int>) {
                    guard ids.count >= 3 else { return }
                    let a = ids[ids.startIndex]
                    for k in (ids.startIndex + 1)..<(ids.endIndex - 1) {
                        let b = ids[k], c = ids[k + 1]
                        if a >= 0, b >= 0, c >= 0, a < nverts, b < nverts, c < nverts {
                            sub.addTriangle(UInt32(a), UInt32(b), UInt32(c))
                        }
                    }
                }

                switch prim.name {
                case "triangles":
                    for p in prim.children("p") {
                        let ids = vertexIndices(p.numbers)
                        var i = 0
                        while i + 2 < ids.count { addPolygon(ids[i..<(i + 3)]); i += 3 }
                    }
                case "polylist":
                    let counts = prim.child("vcount")?.numbers.map { Int($0) } ?? []
                    let ids = vertexIndices(prim.child("p")?.numbers ?? [])
                    var i = 0
                    for c in counts { if i + c <= ids.count { addPolygon(ids[i..<(i + c)]) }; i += c }
                case "polygons", "trifans":
                    for p in prim.children("p") { let ids = vertexIndices(p.numbers); addPolygon(ids[...]) }
                case "tristrips":
                    for p in prim.children("p") {
                        let ids = vertexIndices(p.numbers)
                        if ids.count >= 3 {
                            for i in 0..<(ids.count - 2) {
                                let t = i % 2 == 0 ? [ids[i], ids[i + 1], ids[i + 2]] : [ids[i + 1], ids[i], ids[i + 2]]
                                addPolygon(t[...])
                            }
                        }
                    }
                default: break
                }
                _ = base
                out.append(sub)
            }
            geomCache[ObjectIdentifier(g)] = out
            return out
        }

        var result = Mesh()

        func localTransform(_ node: XMLNode) -> Transform {
            // Collada transforms are column-vector; listed elements compose left to right,
            // so the last one is applied first.
            var t = Transform.identity
            for el in node.children.reversed() {
                let v = el.numbers
                var step: Transform? = nil
                switch el.name {
                case "matrix" where v.count == 16:
                    // row-major → column-major
                    var c = [Double](repeating: 0, count: 16)
                    for r in 0..<4 { for k in 0..<4 { c[k * 4 + r] = v[r * 4 + k] } }
                    step = .fromColumnMajor4x4(c)
                case "translate" where v.count == 3:
                    step = .fromTRS(t: v, r: nil, s: nil)
                case "scale" where v.count == 3:
                    step = .fromTRS(t: nil, r: nil, s: v)
                case "rotate" where v.count == 4:
                    step = .fromTRS(t: nil, r: axisAngleQuat(v[0], v[1], v[2], v[3] * .pi / 180), s: nil)
                default: break
                }
                if let s = step { t = t.then(s) }
            }
            return t
        }

        func visit(_ node: XMLNode, _ parent: Transform, _ depth: Int) {
            guard depth < 64 else { return }
            let world = localTransform(node).then(parent)
            for c in node.children {
                switch c.name {
                case "instance_geometry":
                    if let g = ref(c.attributes["url"]) { result.append(geometryMesh(g), transform: world) }
                case "instance_node":
                    if let n = ref(c.attributes["url"]) { visit(n, world, depth + 1) }
                case "node":
                    visit(c, world, depth + 1)
                default: break
                }
            }
        }

        var scene: XMLNode? = nil
        if let inst = root.child("scene")?.child("instance_visual_scene") { scene = ref(inst.attributes["url"]) }
        if scene == nil { scene = root.child("library_visual_scenes")?.child("visual_scene") }
        if let scene = scene {
            for n in scene.children("node") { visit(n, .identity, 0) }
        }
        if result.isEmpty {
            for g in root.child("library_geometries")?.children("geometry") ?? [] { result.append(geometryMesh(g)) }
        }
        if result.isEmpty { throw ModelError.empty }
        result.sanitize()

        switch root.child("asset")?.child("up_axis")?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Z_UP": break
        case "X_UP": rotateXUpToZUp(&result)
        default: result.convertYUpToZUp()  // Y_UP is the Collada default
        }
        return result
    }

    static func axisAngleQuat(_ x: Double, _ y: Double, _ z: Double, _ angle: Double) -> [Double] {
        let l = (x * x + y * y + z * z).squareRoot()
        guard l > 0 else { return [0, 0, 0, 1] }
        let s = sin(angle / 2) / l
        return [x * s, y * s, z * s, cos(angle / 2)]
    }

    static func rotateXUpToZUp(_ m: inout Mesh) {
        var i = 0
        while i + 2 < m.positions.count {
            let x = m.positions[i], z = m.positions[i + 2]
            m.positions[i] = -z
            m.positions[i + 2] = x
            i += 3
        }
    }
}
