import Foundation

/// Formats whose icon is a preview image stored inside the file.
public enum LoaderPreviews {

    // MARK: - ZIP containers (Cura UFP, FreeCAD, Prusa SL1)

    /// Largest PNG/JPEG whose path contains one of `hints` (case-insensitive).
    public static func zipImage(_ data: Data, hints: [String]) throws -> Data {
        let zip = try ZipArchive(data)
        var best: Data? = nil
        for e in zip.entries {
            let n = e.name.lowercased()
            guard n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".jpeg") else { continue }
            guard hints.contains(where: { n.contains($0) }) else { continue }
            guard let d = try? zip.extract(e), d.isPNG || d.isJPEG else { continue }
            if best == nil || d.count > best!.count { best = d }
        }
        guard let img = best else { throw ModelError.unsupported("no preview image") }
        return img
    }

    // MARK: - LightBurn (.lbrn / .lbrn2)

    /// <Thumbnail Source="base64 PNG"/>
    public static func lightBurn(_ data: Data) throws -> Data {
        let text = String(decoding: data.prefix(32 << 20), as: UTF8.self)
        guard let tag = text.range(of: "<Thumbnail"),
              let src = text.range(of: "Source=\"", range: tag.upperBound..<text.endIndex),
              let end = text.range(of: "\"", range: src.upperBound..<text.endIndex) else {
            throw ModelError.unsupported("no LightBurn thumbnail")
        }
        let b64 = String(text[src.upperBound..<end.lowerBound])
        guard let img = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), img.isPNG || img.isJPEG else {
            throw ModelError.malformed("LightBurn thumbnail")
        }
        return img
    }

    // MARK: - Resin printers

    /// Chitubox family (.ctb incl. encrypted v4, .cbddlp, .photon, .phz, GKtwo).
    /// Instead of decoding (possibly encrypted) headers, scan for preview records:
    /// {width, height, imageOffset = here + 32, imageLength, 4 × reserved} followed by RLE data.
    public static func chitubox(_ data: Data) throws -> Data {
        let r = BinaryReader(data)
        let limit = min(data.count - 32, 16 << 20)
        var best: Image? = nil
        var p = 0
        while p < limit {
            if let w = r.peekU32(at: p), w >= 16, w <= 2048,
               let h = r.peekU32(at: p + 4), h >= 16, h <= 2048,
               let off = r.peekU32(at: p + 8), Int(off) == p + 32,
               let len = r.peekU32(at: p + 12), len > 0, Int(off) + Int(len) <= data.count,
               Int(len) <= Int(w) * Int(h) * 4 + 64 {
                if let img = ImageDecode.chituRLE(data, offset: Int(off), length: Int(len), width: Int(w), height: Int(h)) {
                    if best == nil || img.width * img.height > best!.width * best!.height { best = img }
                    p = Int(off) + Int(len)
                    continue
                }
            }
            p += 4
        }
        guard let img = best else { throw ModelError.unsupported("no Chitubox preview found") }
        return ImageDecode.png(img)
    }

    /// Elegoo GOO / Phrozen PRZ: fixed-position RGB565 previews (116² and 290²).
    public static func goo(_ data: Data) throws -> Data {
        let version = String(decoding: data.prefix(4), as: UTF8.self)
        guard version.hasPrefix("V") else { throw ModelError.malformed("not a GOO file") }
        let bigEndian = !version.hasPrefix("V5")  // v3 previews are big-endian, v5 little-endian
        let bigOffset = 194 + 116 * 116 * 2 + 2
        guard let img = ImageDecode.rgb565(data, offset: bigOffset, width: 290, height: 290, bigEndian: bigEndian)
                ?? ImageDecode.rgb565(data, offset: 194, width: 116, height: 116, bigEndian: bigEndian) else {
            throw ModelError.malformed("GOO preview")
        }
        return ImageDecode.png(img)
    }

    /// Anycubic Photon Workshop (.pwmx, .pwma, .pm3, .dlp, ...): "PREVIEW" table with RGB565.
    public static func anycubic(_ data: Data) throws -> Data {
        guard data.starts(with: Array("ANYCUBIC".utf8)) else { throw ModelError.malformed("not an Anycubic file") }
        let mark = Array("PREVIEW".utf8)
        let limit = min(data.count, 4 << 20)
        let r = BinaryReader(data)
        let found: Int? = data.withUnsafeBytes { raw -> Int? in
            var i = 0
            while i + 32 < limit {
                if raw[i] == 0x50 {
                    var ok = true
                    for k in 0..<mark.count where raw[i + k] != mark[k] { ok = false; break }
                    if ok && raw[i + 7] == 0 { return i }
                }
                i += 1
            }
            return nil
        }
        guard let t = found, let w = r.peekU32(at: t + 16), let h = r.peekU32(at: t + 24),
              w > 0, h > 0, w <= 2048, h <= 2048,
              let img = ImageDecode.rgb565(data, offset: t + 28, width: Int(w), height: Int(h), bigEndian: false) else {
            throw ModelError.unsupported("no Anycubic preview")
        }
        return ImageDecode.png(img)
    }

    // MARK: - Rhino (.3dm)

    /// TCODE_PROPERTIES_COMPRESSED_PREVIEWIMAGE (0x20008025): BITMAPINFOHEADER then a
    /// zlib-compressed 24-bit DIB. Older/uncompressed form 0x20008023 holds the DIB directly.
    public static func rhino(_ data: Data) throws -> Data {
        guard data.starts(with: Array("3D Geometry File Format".utf8)) else { throw ModelError.malformed("not a 3dm file") }
        let window = data.prefix(min(data.count, 32 << 20))
        for code: UInt32 in [0x20008025, 0x20008023] {
            let pattern = withUnsafeBytes(of: code.littleEndian) { Data($0) }
            guard let hit = window.range(of: pattern) else { continue }
            let at = hit.lowerBound - data.startIndex
            // Chunk length is 4 bytes (V1-V4) or 8 bytes (V5+); find the 40-byte header.
            for headerOff in [at + 8, at + 12] {
                let r = BinaryReader(data)
                guard r.peekU32(at: headerOff) == 40,
                      let w = r.peekU32(at: headerOff + 4), let h = r.peekU32(at: headerOff + 8),
                      w > 0, w <= 4096, Int32(bitPattern: h) != 0,
                      let bpp = r.peekU16(at: headerOff + 14), bpp == 24 || bpp == 32 || bpp == 8 else { continue }
                if code == 0x20008023 {
                    if let img = ImageDecode.dib(data, headerOffset: headerOff) { return ImageDecode.png(img) }
                    continue
                }
                // Compressed: search for the zlib header shortly after the bitmap header.
                let sizeImage = Int(r.peekU32(at: headerOff + 20) ?? 0)
                let clrUsed = Int(r.peekU32(at: headerOff + 32) ?? 0)
                let palette = bpp == 8 ? (clrUsed == 0 ? 256 : clrUsed) * 4 : 0
                // The compressed bytes sit in an anonymous chunk (typecode 0x40008000) right after
                // the buffer size / CRC fields; start the zlib search after that marker.
                var q = headerOff + 40
                let marker: [UInt8] = [0x00, 0x80, 0x00, 0x40]
                var m = q
                while m < min(headerOff + 80, data.count - 4) {
                    if (0..<4).allSatisfy({ data[data.startIndex + m + $0] == marker[$0] }) { q = m + 4; break }
                    m += 1
                }
                while q < min(headerOff + 120, data.count - 2) {
                    let b0 = data[data.startIndex + q], b1 = data[data.startIndex + q + 1]
                    if b0 == 0x78 && (UInt16(b0) << 8 | UInt16(b1)) % 31 == 0 {
                        let s = data.startIndex + q + 2
                        let pixels = ZipArchive.inflatePrefix(data.subdata(in: s..<data.endIndex),
                                                              maxOutput: palette + max(sizeImage, Int(w) * 4 * Int(abs(Int32(bitPattern: h)))))
                        // Rebuild a contiguous DIB: header + palette + pixels.
                        var dib = data.subdata(in: (data.startIndex + headerOff)..<(data.startIndex + headerOff + 40))
                        dib.append(pixels)
                        if let img = ImageDecode.dib(dib, headerOffset: 0) { return ImageDecode.png(img) }
                        break
                    }
                    q += 1
                }
            }
        }
        throw ModelError.unsupported("no preview stored in 3dm")
    }

    // MARK: - Blender (.blend)

    /// The "TEST" block holds the thumbnail: int width, int height, RGBA (bottom-up).
    /// Handles plain and gzip-compressed files; zstd-compressed files (Blender 3.0+
    /// "Compress" option) aren't supported.
    public static func blender(_ fileData: Data) throws -> Data {
        var data = fileData
        if data.starts(with: [0x1F, 0x8B]) {
            data = try gunzipPrefix(data, maxOutput: 32 << 20)
        } else if data.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            throw ModelError.unsupported("zstd-compressed .blend")
        }
        guard data.count > 24, data.starts(with: Array("BLENDER".utf8)) else { throw ModelError.malformed("not a .blend") }
        let bytes = [UInt8](data.prefix(24))
        var pointerSize = 8
        var bigEndian = false
        var headerSize = 12
        var largeHeads = false
        if bytes[7] == 0x5F || bytes[7] == 0x2D { // '_' 4-byte pointers, '-' 8-byte (classic header)
            pointerSize = bytes[7] == 0x5F ? 4 : 8
            bigEndian = bytes[8] == 0x56 // 'V'
        } else if let hs = Int(String(decoding: bytes[7..<9], as: UTF8.self)) { // Blender 5.0+: "BLENDER17-01v0500"
            headerSize = hs
            largeHeads = true
            bigEndian = bytes[12] == 0x56
        } else {
            throw ModelError.malformed("unknown .blend header")
        }
        var r = BinaryReader(data, bigEndian: bigEndian)
        r.offset = headerSize
        while r.remaining > 16 {
            guard let code = r.bytes(4) else { break }
            var length = 0
            if largeHeads {
                _ = r.u32()                 // SDNA index
                _ = r.u64()                 // old pointer
                length = Int(r.u64() ?? 0)
                _ = r.u64()                 // count
            } else {
                length = Int(r.i32() ?? 0)
                r.offset += pointerSize + 8 // old pointer, SDNA index, count
            }
            let name = String(decoding: code, as: UTF8.self)
            if name == "TEST" {
                guard let w = r.i32(), let h = r.i32(), w > 0, h > 0, w <= 1024, h <= 1024 else { break }
                let W = Int(w), H = Int(h)
                guard let px = r.bytes(W * H * 4) else { break }
                var out = [UInt8](repeating: 0, count: W * H * 4)
                px.withUnsafeBytes { raw in
                    for y in 0..<H {
                        let src = (H - 1 - y) * W * 4
                        for x in 0..<W {
                            let s = src + x * 4, d = (y * W + x) * 4
                            let a = UInt16(raw[s + 3])
                            out[d] = UInt8(UInt16(raw[s]) * a / 255)
                            out[d + 1] = UInt8(UInt16(raw[s + 1]) * a / 255)
                            out[d + 2] = UInt8(UInt16(raw[s + 2]) * a / 255)
                            out[d + 3] = UInt8(a)
                        }
                    }
                }
                return ImageDecode.png(Image(width: W, height: H, pixels: out))
            }
            if name == "DNA1" || name == "ENDB" || length < 0 { break }
            r.offset += length
        }
        throw ModelError.unsupported("no thumbnail saved in .blend")
    }

    static func gunzipPrefix(_ data: Data, maxOutput: Int) throws -> Data {
        guard data.count > 18 else { throw ModelError.malformed("gzip") }
        let b = [UInt8](data.prefix(10))
        let flags = b[3]
        var p = 10
        if flags & 0x04 != 0 { // FEXTRA
            let xlen = Int(data[data.startIndex + p]) | Int(data[data.startIndex + p + 1]) << 8
            p += 2 + xlen
        }
        if flags & 0x08 != 0 { while p < data.count && data[data.startIndex + p] != 0 { p += 1 }; p += 1 } // FNAME
        if flags & 0x10 != 0 { while p < data.count && data[data.startIndex + p] != 0 { p += 1 }; p += 1 } // FCOMMENT
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        return ZipArchive.inflatePrefix(data.subdata(in: (data.startIndex + p)..<data.endIndex), maxOutput: maxOutput)
    }

    // MARK: - SketchUp, SolidWorks, Inventor, generic

    /// SketchUp (.skp) and SolidWorks 2015+ files embed a PNG preview; OLE-based files
    /// (older SolidWorks, Inventor) are searched stream by stream, including the
    /// document summary thumbnail.
    /// SketchUp writes the document thumbnail first, after a "CDib" tag; later images are
    /// component previews and textures.
    public static func sketchUp(_ data: Data) throws -> Data {
        let window = data.prefix(min(data.count, 4 << 20))
        if let tag = window.range(of: Data("CDib".utf8)) {
            let after = data.subdata(in: tag.upperBound..<min(data.endIndex, tag.upperBound + (8 << 20)))
            if let png = ImageDecode.firstEmbeddedPNG(after.prefix(64)) ?? ImageDecode.firstEmbeddedPNG(after) { return png }
        }
        if let png = ImageDecode.firstEmbeddedPNG(data) { return png }
        throw ModelError.unsupported("no SketchUp thumbnail")
    }

    public static func embedded(_ data: Data) throws -> Data {
        if CompoundFile.looksLikeCFB(data), let cfb = try? CompoundFile(data) {
            if let img = cfb.thumbnail() { return img }
        }
        if let img = solidWorksBlocks(data) { return img }
        if let png = ImageDecode.largestEmbeddedPNG(data, minSide: 32) { return png }
        throw ModelError.unsupported("no embedded preview found")
    }

    /// SolidWorks 2015+ container: blocks introduced by the marker 14 00 06 00 08 00,
    /// followed by type, CRC-32, compressed size, uncompressed size, name length,
    /// a nibble-swapped name, and raw DEFLATE data. The preview is a block whose
    /// payload is a PNG (named "PreviewPNG"), or a bitmap thumbnail.
    static func solidWorksBlocks(_ data: Data) -> Data? {
        let marker: [UInt8] = [0x14, 0x00, 0x06, 0x00, 0x08, 0x00]
        let r = BinaryReader(data)
        struct Block { let name: String; let start: Int; let comp: Int; let uncomp: Int }
        var blocks: [Block] = []
        data.withUnsafeBytes { raw in
            var i = 0
            while i + 26 <= raw.count {
                if raw[i] != 0x14 || raw[i + 1] != 0x00 { i += 1; continue }
                var match = true
                for k in 2..<6 where raw[i + k] != marker[k] { match = false; break }
                guard match, let comp = r.peekU32(at: i + 14), let uncomp = r.peekU32(at: i + 18),
                      let pre = r.peekU32(at: i + 22), comp > 0, pre < 1024, uncomp < 512 << 20,
                      i + 26 + Int(pre) + Int(comp) <= raw.count else { i += 1; continue }
                var name = ""
                for k in 0..<Int(pre) {
                    let b = raw[i + 26 + k]
                    let c = (b << 4) | (b >> 4)   // nibble swap
                    name.append(Character(UnicodeScalar(c)))
                }
                blocks.append(Block(name: name, start: i + 26 + Int(pre), comp: Int(comp), uncomp: Int(uncomp)))
                i += 6  // other record types share the marker; don't skip past real blocks
            }
        }
        guard !blocks.isEmpty else { return nil }
        // Named previews first, then any small block that turns out to be an image.
        let ordered = blocks.filter { $0.name.lowercased().contains("preview") }
            + blocks.filter { !$0.name.lowercased().contains("preview") && $0.uncomp < 8 << 20 }
        var best: Data? = nil
        for b in ordered {
            let s = data.startIndex + b.start
            guard let payload = try? ZipArchive.inflate(data.subdata(in: s..<(s + b.comp)), expectedSize: b.uncomp) else { continue }
            if payload.isPNG || payload.isJPEG {
                if best == nil || payload.count > best!.count { best = payload }
            } else if best == nil, payload.count > 44, BinaryReader(payload).peekU32(at: 4) == 40,
                      let img = ImageDecode.dib(payload, headerOffset: 4) {
                best = ImageDecode.png(img)
            }
            if best != nil && b.name.lowercased().contains("preview") { break }
        }
        return best
    }
}

/// Minimal reader for OLE / Compound File Binary documents.
struct CompoundFile {
    struct Entry { let name: String; let type: UInt8; let start: UInt32; let size: Int }

    let data: Data
    let sectorSize: Int
    let miniSectorSize: Int
    let miniCutoff: Int
    var fat: [UInt32] = []
    var miniFat: [UInt32] = []
    var entries: [Entry] = []
    var miniStream = Data()

    static func looksLikeCFB(_ d: Data) -> Bool {
        d.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    init(_ data: Data) throws {
        self.data = data
        let r = BinaryReader(data)
        sectorSize = 1 << Int(r.peekU16(at: 0x1E) ?? 9)
        miniSectorSize = 1 << Int(r.peekU16(at: 0x20) ?? 6)
        miniCutoff = Int(r.peekU32(at: 0x38) ?? 4096)
        guard sectorSize == 512 || sectorSize == 4096 else { throw ModelError.malformed("cfb sector size") }

        // DIFAT → FAT sector list
        var fatSectors: [UInt32] = []
        for i in 0..<109 { if let s = r.peekU32(at: 0x4C + i * 4), s < 0xFFFFFFFA { fatSectors.append(s) } }
        var difat = r.peekU32(at: 0x44) ?? 0xFFFFFFFE
        var guardCount = 0
        while difat < 0xFFFFFFFA && guardCount < 10000 {
            let base = Int(difat + 1) * sectorSize
            let per = sectorSize / 4 - 1
            for i in 0..<per { if let s = r.peekU32(at: base + i * 4), s < 0xFFFFFFFA { fatSectors.append(s) } }
            difat = r.peekU32(at: base + per * 4) ?? 0xFFFFFFFE
            guardCount += 1
        }
        for s in fatSectors {
            let base = Int(s + 1) * sectorSize
            for i in 0..<(sectorSize / 4) { fat.append(r.peekU32(at: base + i * 4) ?? 0xFFFFFFFF) }
        }

        // Directory
        let dir = chain(r.peekU32(at: 0x30) ?? 0)
        var i = 0
        while i + 128 <= dir.count {
            let er = BinaryReader(dir)
            let nameLen = Int(er.peekU16(at: i + 64) ?? 0)
            let nameData = dir.subdata(in: (dir.startIndex + i)..<(dir.startIndex + i + max(0, min(64, nameLen) - 2)))
            let name = String(decoding: nameData.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }, as: UTF16.self)
            let type = dir[dir.startIndex + i + 66]
            let start = er.peekU32(at: i + 116) ?? 0
            let size = Int(er.peekU32(at: i + 120) ?? 0)
            entries.append(Entry(name: name, type: type, start: start, size: size))
            i += 128
        }

        // Mini stream + mini FAT
        if let root = entries.first(where: { $0.type == 5 }) {
            miniStream = chain(root.start, limit: root.size)
        }
        let mf = chain(r.peekU32(at: 0x3C) ?? 0xFFFFFFFE)
        let mr = BinaryReader(mf)
        for k in 0..<(mf.count / 4) { miniFat.append(mr.peekU32(at: k * 4) ?? 0xFFFFFFFF) }
    }

    func chain(_ start: UInt32, limit: Int = Int.max) -> Data {
        var out = Data()
        var s = start
        var steps = 0
        while s < 0xFFFFFFFA && Int(s) < fat.count + 1 && steps < 1_000_000 && out.count < limit {
            let base = Int(s + 1) * sectorSize
            guard base + sectorSize <= data.count else { break }
            out.append(data.subdata(in: (data.startIndex + base)..<(data.startIndex + base + sectorSize)))
            guard Int(s) < fat.count else { break }
            s = fat[Int(s)]
            steps += 1
        }
        if out.count > limit { out.count = limit }
        return out
    }

    func miniChain(_ start: UInt32, size: Int) -> Data {
        var out = Data()
        var s = start
        var steps = 0
        while s < 0xFFFFFFFA && out.count < size && steps < 1_000_000 {
            let base = Int(s) * miniSectorSize
            guard base + miniSectorSize <= miniStream.count else { break }
            out.append(miniStream.subdata(in: (miniStream.startIndex + base)..<(miniStream.startIndex + base + miniSectorSize)))
            guard Int(s) < miniFat.count else { break }
            s = miniFat[Int(s)]
            steps += 1
        }
        if out.count > size { out.count = size }
        return out
    }

    func stream(_ e: Entry) -> Data {
        e.size < miniCutoff ? miniChain(e.start, size: e.size) : chain(e.start, limit: e.size)
    }

    /// Best preview: an embedded PNG/JPEG in a preview-like stream, any PNG in any
    /// stream, or the clipboard thumbnail in the SummaryInformation property set.
    func thumbnail() -> Data? {
        let streams = entries.filter { $0.type == 2 && $0.size > 0 }
        let ordered = streams.sorted { a, b in
            let pa = a.name.lowercased().contains("preview") || a.name.lowercased().contains("thumb")
            let pb = b.name.lowercased().contains("preview") || b.name.lowercased().contains("thumb")
            return pa && !pb
        }
        for e in ordered {
            let d = stream(e)
            if d.isPNG || d.isJPEG { return d }
            if let png = ImageDecode.largestEmbeddedPNG(d, minSide: 32) { return png }
            if e.name.lowercased().contains("preview") {
                if let j = ImageDecode.jpegAt(d, start: 0) { return j }
                if let img = ImageDecode.dib(d, headerOffset: 0) { return ImageDecode.png(img) }
            }
        }
        if let si = streams.first(where: { $0.name == "\u{5}SummaryInformation" }) {
            return summaryThumbnail(stream(si))
        }
        return nil
    }

    /// PIDSI_THUMBNAIL (0x11), VT_CF: clipboard data, usually CF_DIB.
    func summaryThumbnail(_ d: Data) -> Data? {
        let r = BinaryReader(d)
        guard let sectionOffset = r.peekU32(at: 44) else { return nil }
        let s = Int(sectionOffset)
        guard let count = r.peekU32(at: s + 4), count < 1000 else { return nil }
        for k in 0..<Int(count) {
            guard let pid = r.peekU32(at: s + 8 + k * 8), let off = r.peekU32(at: s + 12 + k * 8) else { continue }
            guard pid == 0x11 else { continue }
            let p = s + Int(off)
            guard r.peekU32(at: p) == 0x47, let size = r.peekU32(at: p + 4), let fmt = r.peekU32(at: p + 8) else { return nil }
            var payload = p + 12
            if Int32(bitPattern: fmt) == -1 { // Windows clipboard format id follows
                let cf = r.peekU32(at: payload) ?? 0
                payload += 4
                if cf == 8, let img = ImageDecode.dib(d, headerOffset: payload) { return ImageDecode.png(img) }
            }
            let end = min(d.count, p + 8 + Int(size))
            if end > payload, let png = ImageDecode.largestEmbeddedPNG(d.subdata(in: (d.startIndex + payload)..<(d.startIndex + end)), minSide: 16) {
                return png
            }
        }
        return nil
    }
}
