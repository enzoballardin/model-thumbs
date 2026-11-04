import Foundation

#if MT_HAS_OCCT
/// Bridges the OpenCASCADE C shim (mt_cad.cpp) into a Mesh.
enum CADLoader {
    static func load(_ url: URL, _ ext: String) throws -> Mesh {
        let kind: Int32
        switch ext {
        case "iges", "igs": kind = 1
        case "brep", "brp": kind = 2
        default: kind = 0
        }
        var raw = MTCadMesh()
        let rc = url.withUnsafeFileSystemRepresentation { mt_cad_load($0, kind, &raw) }
        defer { mt_cad_free(&raw) }
        guard rc == 0, raw.vertexCount > 0, raw.indexCount > 0,
              let p = raw.positions, let i = raw.indices else {
            let msg = withUnsafeBytes(of: raw.error) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            throw ModelError.malformed(msg.isEmpty ? "CAD import failed" : msg)
        }
        var m = Mesh()
        m.positions = Array(UnsafeBufferPointer(start: p, count: Int(raw.vertexCount) * 3))
        m.indices = Array(UnsafeBufferPointer(start: i, count: Int(raw.indexCount)))
        return m
    }
}
#endif
