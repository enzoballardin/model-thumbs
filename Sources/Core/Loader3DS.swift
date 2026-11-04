import Foundation

/// 3D Studio (.3ds): chunked binary. Vertices are stored in world space.
public enum Loader3DS {
    public static func load(_ data: Data) throws -> Mesh {
        let r = BinaryReader(data)
        guard r.peekU16(at: 0) == 0x4D4D else { throw ModelError.malformed("not a 3ds file") }
        var out = Mesh()
        var current = Mesh()

        func flush() {
            if !current.indices.isEmpty { current.sanitize(); out.append(current) }
            current = Mesh()
        }

        func walk(_ start: Int, _ end: Int, _ depth: Int) {
            guard depth < 16 else { return }
            var p = start
            while p + 6 <= end {
                guard let id = r.peekU16(at: p), let len32 = r.peekU32(at: p + 2) else { return }
                let len = Int(len32)
                guard len >= 6, p + len <= end else { return }
                let body = p + 6
                switch id {
                case 0x4D4D, 0x3D3D:                      // main, editor
                    walk(body, p + len, depth + 1)
                case 0x4000:                              // named object: C string, then sub-chunks
                    var q = body
                    while q < p + len, data[data.startIndex + q] != 0 { q += 1 }
                    walk(q + 1, p + len, depth + 1)
                case 0x4100:                              // triangle mesh
                    flush()
                    walk(body, p + len, depth + 1)
                    flush()
                case 0x4110:                              // vertex list
                    let n = Int(r.peekU16(at: body) ?? 0)
                    guard body + 2 + n * 12 <= data.count else { break }
                    data.withUnsafeBytes { raw in
                        for i in 0..<n {
                            let o = body + 2 + i * 12
                            current.addVertex(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                              raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                              raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                        }
                    }
                case 0x4120:                              // face list (a, b, c, flags)
                    let n = Int(r.peekU16(at: body) ?? 0)
                    for i in 0..<n {
                        let o = body + 2 + i * 8
                        guard let a = r.peekU16(at: o), let b = r.peekU16(at: o + 2), let c = r.peekU16(at: o + 4) else { break }
                        current.addTriangle(UInt32(a), UInt32(b), UInt32(c))
                    }
                default:
                    break
                }
                p += len
            }
        }
        walk(0, data.count, 0)
        flush()
        if out.isEmpty { throw ModelError.empty }
        return out
    }
}
