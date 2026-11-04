import Foundation

/// ASTM E57 3D imaging files (terrestrial / mobile scanners).
/// Reads every scan's cartesian (or spherical) coordinates from the compressed
/// vectors, applies each scan's pose, and subsamples evenly to keep thumbnails fast.
public enum LoaderE57 {
    static let maxPoints = 3_000_000

    public static func load(_ data: Data) throws -> Mesh {
        guard data.starts(with: Array("ASTM-E57".utf8)) else { throw ModelError.malformed("not an E57 file") }
        let r = BinaryReader(data)
        guard let xmlOffset = r.peekU32(at: 24).map({ _ in Int(readU64(r, 24)) }),
              let _ = r.peekU32(at: 32) else { throw ModelError.malformed("e57 header") }
        let xmlLength = Int(readU64(r, 32))
        var pageSize = Int(readU64(r, 40))
        if pageSize <= 4 || pageSize > 1 << 20 { pageSize = 1024 }

        var cursor = Cursor(data: data, pageSize: pageSize, physical: xmlOffset)
        guard let xmlData = cursor.read(xmlLength), let root = XMLNode.parse(xmlData) else {
            throw ModelError.malformed("e57 xml")
        }
        guard let data3D = root.child("data3D") else { throw ModelError.empty }
        let scans = data3D.children("vectorChild")

        let totalRecords = scans.reduce(0) { $0 + (Int($1.child("points")?.attributes["recordCount"] ?? "0") ?? 0) }
        let stride = max(1, (totalRecords + maxPoints - 1) / maxPoints)

        var mesh = Mesh()
        var origin: (Double, Double, Double)? = nil   // recentre in double precision
        for scan in scans {
            guard let points = scan.child("points"), points.attributes["type"] == "CompressedVector",
                  let fileOffset = Int(points.attributes["fileOffset"] ?? ""),
                  let count = Int(points.attributes["recordCount"] ?? ""), count > 0,
                  let proto = points.child("prototype") else { continue }
            let pose = poseTransform(scan.child("pose"))
            let fields = proto.children.map { Field($0) }
            func idx(_ n: String) -> Int? { fields.firstIndex { $0.name == n } }

            let cart = [idx("cartesianX"), idx("cartesianY"), idx("cartesianZ")]
            let sph = [idx("sphericalRange"), idx("sphericalAzimuth"), idx("sphericalElevation")]
            let useCart = cart.allSatisfy { $0 != nil }
            guard useCart || sph.allSatisfy({ $0 != nil }) else { continue }
            let main = (useCart ? cart : sph).map { $0! }
            let invalid = idx(useCart ? "cartesianInvalidState" : "sphericalInvalidState")

            var wanted = main
            if let inv = invalid { wanted.append(inv) }
            guard let values = try? decodeStreams(data: data, pageSize: pageSize, fileOffset: fileOffset,
                                                  recordCount: count, fields: fields, wanted: wanted, stride: stride) else { continue }
            let a = values[main[0]]!, b = values[main[1]]!, c = values[main[2]]!
            let inv = invalid.flatMap { values[$0] }
            let n = min(a.count, b.count, c.count)
            mesh.positions.reserveCapacity(mesh.positions.count + n * 3)
            for i in 0..<n {
                if let inv = inv, i < inv.count, inv[i] != 0 { continue }
                var x = a[i], y = b[i], z = c[i]
                if !useCart {
                    let range = a[i], az = b[i], el = c[i]
                    x = range * cos(el) * cos(az); y = range * cos(el) * sin(az); z = range * sin(el)
                }
                let (px, py, pz) = pose.apply(x, y, z)
                if origin == nil { origin = (px, py, pz) }
                mesh.addVertex(Float(px - origin!.0), Float(py - origin!.1), Float(pz - origin!.2))
            }
        }
        if mesh.isEmpty { throw ModelError.empty }
        return mesh
    }

    static func readU64(_ r: BinaryReader, _ at: Int) -> UInt64 {
        UInt64(r.peekU32(at: at) ?? 0) | UInt64(r.peekU32(at: at + 4) ?? 0) << 32
    }

    // MARK: Pose

    /// Rigid transform in double precision: rotation quaternion (x, y, z, w) + translation.
    struct Pose {
        var q = (0.0, 0.0, 0.0, 1.0)
        var t = (0.0, 0.0, 0.0)
        func apply(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let (qx, qy, qz, qw) = q
            // v' = v + 2w(q×v) + 2 q×(q×v)
            let cx = qy * z - qz * y, cy = qz * x - qx * z, cz = qx * y - qy * x
            let dx = qy * cz - qz * cy, dy = qz * cx - qx * cz, dz = qx * cy - qy * cx
            return (x + 2 * (qw * cx + dx) + t.0, y + 2 * (qw * cy + dy) + t.1, z + 2 * (qw * cz + dz) + t.2)
        }
    }

    static func poseTransform(_ pose: XMLNode?) -> Pose {
        guard let pose = pose else { return Pose() }
        func num(_ n: XMLNode?, _ k: String, _ d: Double) -> Double {
            guard let t = n?.child(k)?.text.trimmingCharacters(in: .whitespacesAndNewlines), let v = Double(t) else { return d }
            return v
        }
        let rot = pose.child("rotation"), tr = pose.child("translation")
        var q = (num(rot, "x", 0), num(rot, "y", 0), num(rot, "z", 0), num(rot, "w", 1))
        let l = (q.0 * q.0 + q.1 * q.1 + q.2 * q.2 + q.3 * q.3).squareRoot()
        if l > 0 { q = (q.0 / l, q.1 / l, q.2 / l, q.3 / l) }
        return Pose(q: q, t: (num(tr, "x", 0), num(tr, "y", 0), num(tr, "z", 0)))
    }

    // MARK: Paged physical file → logical byte stream

    /// E57 pages end with a 4-byte CRC; logical data skips them.
    struct Cursor {
        let data: Data
        let pageSize: Int
        var physical: Int

        mutating func read(_ n: Int) -> Data? {
            guard n >= 0 else { return nil }
            var out = Data(capacity: n)
            var need = n
            let payload = pageSize - 4
            while need > 0 {
                let inPage = physical % pageSize
                if inPage >= payload { physical += pageSize - inPage; continue }
                let take = min(need, payload - inPage)
                guard physical + take <= data.count else { return nil }
                let s = data.startIndex + physical
                out.append(data[s..<(s + take)])
                physical += take
                need -= take
            }
            return out
        }
    }

    // MARK: Field descriptions

    struct Field {
        enum Kind { case float32, float64, integer(bits: Int, min: Int64), scaled(bits: Int, min: Int64, scale: Double, offset: Double) }
        let name: String
        let kind: Kind

        init(_ n: XMLNode) {
            name = n.name
            let a = n.attributes
            func bitsFor(_ lo: Int64, _ hi: Int64) -> Int {
                let span = UInt64(bitPattern: hi &- lo)
                return span == 0 ? 0 : 64 - span.leadingZeroBitCount
            }
            switch a["type"] {
            case "Float":
                kind = a["precision"] == "single" ? .float32 : .float64
            case "ScaledInteger":
                let lo = Int64(a["minimum"] ?? "") ?? Int64(Int32.min), hi = Int64(a["maximum"] ?? "") ?? Int64(Int32.max)
                kind = .scaled(bits: bitsFor(lo, hi), min: lo, scale: Double(a["scale"] ?? "1") ?? 1,
                               offset: Double(a["offset"] ?? "0") ?? 0)
            default: // Integer
                let lo = Int64(a["minimum"] ?? "") ?? Int64.min, hi = Int64(a["maximum"] ?? "") ?? Int64.max
                kind = .integer(bits: bitsFor(lo, hi), min: lo)
            }
        }

        var bitsPerRecord: Int {
            switch kind {
            case .float32: return 32
            case .float64: return 64
            case .integer(let b, _), .scaled(let b, _, _, _): return b
            }
        }
    }

    /// Per-bytestream decoder that carries partial bits across packets.
    struct StreamState {
        var pending: [UInt8] = []
        var bitPos = 0
        var produced = 0       // records decoded so far
        var values: [Double] = []
    }

    static func decodeStreams(data: Data, pageSize: Int, fileOffset: Int, recordCount: Int,
                              fields: [Field], wanted: [Int], stride: Int) throws -> [Int: [Double]] {
        var cur = Cursor(data: data, pageSize: pageSize, physical: fileOffset)
        guard let section = cur.read(32), section[section.startIndex] == 1 else { throw ModelError.malformed("e57 section") }
        let sr = BinaryReader(section)
        let dataOffset = Int(readU64(sr, 16))
        var pc = Cursor(data: data, pageSize: pageSize, physical: dataOffset)

        var states = [Int: StreamState]()
        for w in wanted { states[w] = StreamState() }
        let wantedSet = Set(wanted)

        var guardPackets = 0
        while states.values.contains(where: { $0.produced < recordCount }) && guardPackets < 50_000_000 {
            guardPackets += 1
            guard let head = pc.read(4) else { break }
            let type = head[head.startIndex]
            let length = (Int(head[head.startIndex + 2]) | Int(head[head.startIndex + 3]) << 8) + 1
            guard length >= 4, let body = pc.read(length - 4) else { break }
            if type != 1 { continue } // index (0) or empty (2) packets
            let br = BinaryReader(body)
            let streamCount = Int(br.peekU16(at: 0) ?? 0)
            var bufStart = 2 + streamCount * 2
            for s in 0..<streamCount {
                let len = Int(br.peekU16(at: 2 + s * 2) ?? 0)
                defer { bufStart += len }
                guard wantedSet.contains(s), s < fields.count, var st = states[s] else { continue }
                guard bufStart + len <= body.count else { break }
                // drop fully consumed bytes, append new ones
                let consumed = st.bitPos >> 3
                if consumed > 0 { st.pending.removeFirst(consumed); st.bitPos -= consumed * 8 }
                st.pending.append(contentsOf: body[(body.startIndex + bufStart)..<(body.startIndex + bufStart + len)])
                decodeAvailable(&st, fields[s], recordCount: recordCount, stride: stride)
                states[s] = st
            }
        }
        var out = [Int: [Double]]()
        for (k, v) in states { out[k] = v.values }
        return out
    }

    static func decodeAvailable(_ st: inout StreamState, _ f: Field, recordCount: Int, stride: Int) {
        let bits = f.bitsPerRecord
        if bits == 0 {
            // constant field: every record has the minimum value
            if case .integer(_, let lo) = f.kind {
                while st.produced < recordCount { if st.produced % stride == 0 { st.values.append(Double(lo)) }; st.produced += 1 }
            } else if case .scaled(_, let lo, let sc, let off) = f.kind {
                while st.produced < recordCount { if st.produced % stride == 0 { st.values.append(Double(lo) * sc + off) }; st.produced += 1 }
            }
            return
        }
        let available = st.pending.count * 8
        st.pending.withUnsafeBufferPointer { p in
            while st.bitPos + bits <= available && st.produced < recordCount {
                let keep = st.produced % stride == 0
                if keep {
                    var raw: UInt64 = 0
                    var got = 0
                    var bp = st.bitPos
                    while got < bits {
                        let shift = bp & 7
                        let take = min(8 - shift, bits - got)
                        let chunk = (UInt64(p[bp >> 3]) >> UInt64(shift)) & ((1 << UInt64(take)) - 1)
                        raw |= chunk << UInt64(got)
                        got += take
                        bp += take
                    }
                    let v: Double
                    switch f.kind {
                    case .float32: v = Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
                    case .float64: v = Double(bitPattern: raw)
                    case .integer(_, let lo): v = Double(lo &+ Int64(bitPattern: raw))
                    case .scaled(_, let lo, let sc, let off): v = Double(lo &+ Int64(bitPattern: raw)) * sc + off
                    }
                    st.values.append(v)
                }
                st.bitPos += bits
                st.produced += 1
            }
        }
    }
}
