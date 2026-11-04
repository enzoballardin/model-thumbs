import Foundation

/// AMF (Additive Manufacturing File), plain XML or zipped XML.
public enum LoaderAMF {
    public static func load(_ data: Data) throws -> Mesh {
        var xml = data
        if ZipArchive.looksLikeZip(data) {
            let zip = try ZipArchive(data)
            guard let e = zip.entries.first(where: { !$0.name.hasSuffix("/") }) else { throw ModelError.empty }
            xml = try zip.extract(e)
        }
        var s = XMLScanner(TextBuffer(xml))
        var out = Mesh()
        var objectBase: UInt32 = 0
        var coord = [Float](repeating: 0, count: 3)
        var tri = [Int](repeating: -1, count: 3)
        var field = -1   // which coordinate / vertex slot we are reading
        var inCoordinates = false
        var inTriangle = false

        while true {
            let ev = s.next()
            switch ev {
            case .eof:
                if out.isEmpty { throw ModelError.empty }
                out.sanitize()
                return out
            case .start:
                if s.nameIs("object") {
                    objectBase = UInt32(out.vertexCount)
                } else if s.nameIs("coordinates") {
                    inCoordinates = true; coord = [0, 0, 0]
                } else if s.nameIs("triangle") {
                    inTriangle = true; tri = [-1, -1, -1]
                } else if inCoordinates {
                    field = s.nameIs("x") ? 0 : s.nameIs("y") ? 1 : s.nameIs("z") ? 2 : -1
                } else if inTriangle {
                    field = s.nameIs("v1") ? 0 : s.nameIs("v2") ? 1 : s.nameIs("v3") ? 2 : -1
                }
            case .text:
                guard field >= 0 else { break }
                if inCoordinates, let v = s.textDouble { coord[field] = Float(v) }
                else if inTriangle, let v = s.textDouble { tri[field] = Int(v) }
            case .end:
                if s.nameIs("coordinates") {
                    inCoordinates = false
                    out.addVertex(coord[0], coord[1], coord[2])
                } else if s.nameIs("triangle") {
                    inTriangle = false
                    if tri[0] >= 0 && tri[1] >= 0 && tri[2] >= 0 {
                        out.addTriangle(objectBase + UInt32(tri[0]), objectBase + UInt32(tri[1]), objectBase + UInt32(tri[2]))
                    }
                }
                field = -1
            }
        }
    }
}
