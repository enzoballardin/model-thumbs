import Foundation

/// OBJ, OFF and plain-text point clouds (XYZ / PTS / ASC).
public enum LoaderText {

    // MARK: OBJ

    public static func loadOBJ(_ data: Data) throws -> Mesh {
        let b = TextBuffer(data)
        var mesh = Mesh()
        mesh.positions.reserveCapacity(data.count / 12)
        mesh.indices.reserveCapacity(data.count / 8)
        var pos = 0
        var end = 0
        var face: [Int] = []
        face.reserveCapacity(16)
        let n = b.count
        while pos < n {
            b.skipSpaces(&pos)
            guard pos < n else { break }
            let c = b[pos]
            if c == 118 /* v */ && pos + 1 < n && (b[pos + 1] == 32 || b[pos + 1] == 9) {
                pos += 2
                var xyz: (Double, Double, Double) = (0, 0, 0)
                if let x = b.parseDouble(at: pos, end: &end) { xyz.0 = x; pos = end }
                if let y = b.parseDouble(at: pos, end: &end) { xyz.1 = y; pos = end }
                if let z = b.parseDouble(at: pos, end: &end) { xyz.2 = z; pos = end }
                mesh.addVertex(Float(xyz.0), Float(xyz.1), Float(xyz.2))
            } else if c == 102 /* f */ && pos + 1 < n && (b[pos + 1] == 32 || b[pos + 1] == 9) {
                pos += 2
                face.removeAll(keepingCapacity: true)
                let vc = mesh.vertexCount
                while pos < n {
                    b.skipSpaces(&pos)
                    guard pos < n, b[pos] != 10, b[pos] != 35 else { break }
                    guard let idx = b.parseInt(at: pos, end: &end) else { break }
                    pos = end
                    // skip /vt/vn
                    while pos < n {
                        let ch = b[pos]
                        if ch == 32 || ch == 9 || ch == 10 || ch == 13 { break }
                        pos += 1
                    }
                    let resolved = idx < 0 ? vc + idx : idx - 1
                    face.append(resolved)
                }
                if face.count >= 3 {
                    let a = face[0]
                    for k in 1..<(face.count - 1) {
                        let p = face[k], q = face[k + 1]
                        if a >= 0 && p >= 0 && q >= 0 {
                            mesh.addTriangle(UInt32(a), UInt32(p), UInt32(q))
                        }
                    }
                }
            }
            b.skipToNextLine(&pos)
        }
        if mesh.isEmpty { throw ModelError.empty }
        mesh.sanitize()
        return mesh
    }

    // MARK: OFF

    public static func loadOFF(_ data: Data) throws -> Mesh {
        let b = TextBuffer(data)
        var pos = 0
        var end = 0
        // Collect numbers, skipping comments, after the header keyword.
        func skipWSAndComments() {
            while pos < b.count {
                let c = b[pos]
                if c == 32 || c == 9 || c == 10 || c == 13 { pos += 1 }
                else if c == 35 { b.skipToNextLine(&pos) }
                else { break }
            }
        }
        skipWSAndComments()
        // Header: [ST][C][N][4][n]OFF
        var hasColors = false
        if pos < b.count, b[pos] != 45, !(b[pos] >= 48 && b[pos] <= 57) {
            let hs = pos
            while pos < b.count && b[pos] > 32 { pos += 1 }
            let header = b.string(hs, pos)
            if header.contains("BINARY") { throw ModelError.unsupported("binary OFF") }
            hasColors = header.contains("C")
            _ = hasColors
        }
        skipWSAndComments()
        guard let nv = b.parseInt(at: pos, end: &end) else { throw ModelError.malformed("off header") }
        pos = end; skipWSAndComments()
        guard let nf = b.parseInt(at: pos, end: &end) else { throw ModelError.malformed("off header") }
        pos = end
        b.skipToNextLine(&pos)
        var mesh = Mesh()
        mesh.positions.reserveCapacity(max(0, nv) * 3)
        for _ in 0..<max(0, nv) {
            skipWSAndComments()
            var v: [Double] = [0, 0, 0]
            for k in 0..<3 {
                b.skipSpaces(&pos)
                if let d = b.parseDouble(at: pos, end: &end) { v[k] = d; pos = end }
            }
            mesh.addVertex(Float(v[0]), Float(v[1]), Float(v[2]))
            b.skipToNextLine(&pos)
        }
        for _ in 0..<max(0, nf) {
            skipWSAndComments()
            guard let cnt = b.parseInt(at: pos, end: &end) else { break }
            pos = end
            var ids: [Int] = []
            for _ in 0..<cnt {
                b.skipSpaces(&pos)
                if let i = b.parseInt(at: pos, end: &end) { ids.append(i); pos = end }
            }
            if ids.count >= 3 {
                for k in 1..<(ids.count - 1) where ids[0] >= 0 && ids[k] >= 0 && ids[k + 1] >= 0 {
                    mesh.addTriangle(UInt32(ids[0]), UInt32(ids[k]), UInt32(ids[k + 1]))
                }
            }
            b.skipToNextLine(&pos)
        }
        if mesh.isEmpty { throw ModelError.empty }
        mesh.sanitize()
        return mesh
    }

    // MARK: Point clouds

    /// Each line: x y z [anything...]. Lines that don't start with 3 numbers are skipped
    /// (handles the PTS point-count header and CSV-ish separators).
    public static func loadPointCloud(_ data: Data) throws -> Mesh {
        let b = TextBuffer(data)
        var mesh = Mesh()
        var pos = 0
        var end = 0
        let n = b.count
        while pos < n {
            b.skipSpaces(&pos)
            var v: [Double] = [0, 0, 0]
            var ok = true
            for k in 0..<3 {
                while pos < n && (b[pos] == 32 || b[pos] == 9 || b[pos] == 44 || b[pos] == 59) { pos += 1 }
                if let d = b.parseDouble(at: pos, end: &end), pos < n, b[pos] != 10 { v[k] = d; pos = end }
                else { ok = false; break }
            }
            if ok { mesh.addVertex(Float(v[0]), Float(v[1]), Float(v[2])) }
            b.skipToNextLine(&pos)
        }
        if mesh.isEmpty { throw ModelError.empty }
        return mesh
    }
}
