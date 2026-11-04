import Foundation

/// 3MF (3D Manufacturing Format): a ZIP with XML model parts.
/// Handles plain meshes, components, the Production extension (p:path)
/// used by Bambu Studio / Orca, and the embedded thumbnail.
public enum Loader3MF {
    public static func embeddedThumbnail(_ zip: ZipArchive) -> Data? {
        var candidates: [String] = []
        if let rels = try? zip.extract(named: "_rels/.rels") {
            for rel in relationships(rels) where rel.type.lowercased().hasSuffix("/thumbnail") {
                candidates.append(rel.target)
            }
        }
        candidates += ["Metadata/plate_1.png", "Metadata/thumbnail.png", "Metadata/Thumbnail.png",
                       "Metadata/thumbnail.jpg", "Metadata/plate_1.jpg"]
        for c in candidates {
            if let d = try? zip.extract(named: c), d.isPNG || d.isJPEG, d.count > 100 { return d }
        }
        // Any image in Metadata/ except picking / helper masks
        for e in zip.entries {
            let n = e.name.lowercased()
            guard n.hasPrefix("metadata/"), n.hasSuffix(".png") || n.hasSuffix(".jpg") else { continue }
            if n.contains("pick") || n.contains("_no_light") || n.contains("small") || n.contains("top_") { continue }
            if let d = try? zip.extract(e), d.isPNG || d.isJPEG, d.count > 100 { return d }
        }
        return nil
    }

    struct Relationship { let type: String; let target: String }

    static func relationships(_ data: Data) -> [Relationship] {
        var out: [Relationship] = []
        var s = XMLScanner(TextBuffer(data))
        while true {
            let ev = s.next()
            if case .eof = ev { break }
            if case .start = ev, s.nameIs("Relationship"),
               let t = s.attribute("Type"), let target = s.attribute("Target") {
                out.append(Relationship(type: t, target: target))
            }
        }
        return out
    }

    public static func loadMesh(_ zip: ZipArchive) throws -> Mesh {
        var rootPath = "3D/3dmodel.model"
        if let rels = try? zip.extract(named: "_rels/.rels") {
            for rel in relationships(rels) where rel.type.lowercased().hasSuffix("/3dmodel") {
                rootPath = rel.target
                break
            }
        }
        if zip.entry(named: rootPath) == nil {
            // Fall back to any .model file
            guard let any = zip.entries.first(where: { $0.name.lowercased().hasSuffix(".model") }) else {
                throw ModelError.malformed("3mf: no model part")
            }
            rootPath = any.name
        }
        var ctx = Context(zip: zip)
        let root = try ctx.part(rootPath)
        var result = Mesh()
        let items = root.buildItems.isEmpty
            ? root.objects.keys.sorted().map { BuildItem(objectID: $0, path: nil, transform: .identity) }
            : root.buildItems
        for item in items {
            let path = item.path ?? rootPath
            try ctx.appendObject(item.objectID, inPart: path, transform: item.transform, into: &result, depth: 0)
        }
        if result.isEmpty { throw ModelError.empty }
        result.sanitize()
        return result
    }

    // MARK: - Internals

    struct Component { let objectID: Int; let path: String?; let transform: Transform }
    struct Object { var mesh: Mesh? ; var components: [Component] = [] }
    struct BuildItem { let objectID: Int; let path: String?; let transform: Transform }
    struct Part { var objects: [Int: Object] = [:]; var buildItems: [BuildItem] = [] }

    struct Context {
        let zip: ZipArchive
        var parts: [String: Part] = [:]

        mutating func part(_ path: String) throws -> Part {
            let key = ZipArchive.normalize(path)
            if let p = parts[key] { return p }
            guard let data = try zip.extract(named: path) else {
                throw ModelError.malformed("3mf: missing part \(path)")
            }
            let p = Loader3MF.parsePart(data)
            parts[key] = p
            return p
        }

        mutating func appendObject(_ id: Int, inPart path: String, transform: Transform,
                                   into out: inout Mesh, depth: Int) throws {
            guard depth < 16 else { return }
            let p = try part(path)
            guard let obj = p.objects[id] else { return }
            if let m = obj.mesh, !m.isEmpty { out.append(m, transform: transform) }
            for c in obj.components {
                try appendObject(c.objectID, inPart: c.path ?? path,
                                 transform: c.transform.then(transform), into: &out, depth: depth + 1)
            }
        }
    }

    static func parseTransform(_ s: String?) -> Transform {
        guard let s = s else { return .identity }
        let nums = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," }).compactMap { Float($0) }
        return nums.count == 12 ? Transform(m: nums) : .identity
    }

    static func parsePart(_ data: Data) -> Part {
        var part = Part()
        var s = XMLScanner(TextBuffer(data))
        var currentID: Int? = nil
        var current = Object()
        var mesh = Mesh()
        var inMesh = false
        while true {
            let ev = s.next()
            switch ev {
            case .eof:
                return part
            case .start:
                if s.nameIs("vertex") {
                    if inMesh {
                        var x = 0.0, y = 0.0, z = 0.0
                        var e = 0
                        let tb = s.buf
                        s.forEachShortAttribute { c0, c1, vs in
                            guard c1 == 0 else { return }
                            let v = tb.parseDouble(at: vs, end: &e) ?? 0
                            if c0 == 120 { x = v } else if c0 == 121 { y = v } else if c0 == 122 { z = v }
                        }
                        mesh.addVertex(Float(x), Float(y), Float(z))
                    }
                } else if s.nameIs("triangle") {
                    if inMesh {
                        var a = -1, b = -1, c = -1
                        var e = 0
                        let tb = s.buf
                        s.forEachShortAttribute { c0, c1, vs in
                            guard c0 == 118 else { return } // 'v'
                            let v = tb.parseInt(at: vs, end: &e) ?? -1
                            if c1 == 49 { a = v } else if c1 == 50 { b = v } else if c1 == 51 { c = v }
                        }
                        if a >= 0, b >= 0, c >= 0 { mesh.addTriangle(UInt32(a), UInt32(b), UInt32(c)) }
                    }
                } else if s.nameIs("object") {
                    currentID = s.intAttribute("id")
                    current = Object()
                    if s.selfClosing, let id = currentID { part.objects[id] = current; currentID = nil }
                } else if s.nameIs("mesh") {
                    inMesh = true
                    mesh = Mesh()
                } else if s.nameIs("component") {
                    if let oid = s.intAttribute("objectid") {
                        current.components.append(Component(objectID: oid, path: s.attribute("path"),
                                                            transform: parseTransform(s.attribute("transform"))))
                    }
                } else if s.nameIs("item") {
                    if let oid = s.intAttribute("objectid") {
                        part.buildItems.append(BuildItem(objectID: oid, path: s.attribute("path"),
                                                         transform: parseTransform(s.attribute("transform"))))
                    }
                }
            case .end:
                if s.nameIs("mesh") {
                    inMesh = false
                    current.mesh = mesh
                    mesh = Mesh()
                } else if s.nameIs("object") {
                    if let id = currentID { part.objects[id] = current }
                    currentID = nil
                    current = Object()
                }
            case .text:
                break
            }
        }
    }
}
