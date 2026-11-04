import Foundation

/// Minimal PNG encoder (uncompressed deflate blocks) used by the command-line renderer.
public enum PNGWriter {
    public static func encode(_ img: Image) -> Data {
        // Un-premultiply for PNG (straight alpha)
        var raw = [UInt8]()
        raw.reserveCapacity((img.width * 4 + 1) * img.height)
        for y in 0..<img.height {
            raw.append(0) // filter: none
            for x in 0..<img.width {
                let o = (y * img.width + x) * 4
                let a = img.pixels[o + 3]
                if a == 0 { raw += [0, 0, 0, 0]; continue }
                let f = 255.0 / Double(a)
                raw.append(UInt8(min(255, Double(img.pixels[o]) * f + 0.5)))
                raw.append(UInt8(min(255, Double(img.pixels[o + 1]) * f + 0.5)))
                raw.append(UInt8(min(255, Double(img.pixels[o + 2]) * f + 0.5)))
                raw.append(a)
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE(UInt32(img.width)); ihdr.appendBE(UInt32(img.height))
        ihdr += [8, 6, 0, 0, 0]
        png.appendChunk("IHDR", ihdr)
        png.appendChunk("IDAT", zlibStored(raw))
        png.appendChunk("IEND", Data())
        return png
    }

    static func zlibStored(_ bytes: [UInt8]) -> Data {
        var d = Data([0x78, 0x01])
        var i = 0
        while i < bytes.count || i == 0 {
            let n = min(65535, bytes.count - i)
            let final: UInt8 = (i + n >= bytes.count) ? 1 : 0
            d.append(final)
            d.append(UInt8(n & 0xFF)); d.append(UInt8(n >> 8))
            d.append(UInt8(~n & 0xFF)); d.append(UInt8((~n >> 8) & 0xFF))
            d.append(contentsOf: bytes[i..<(i + n)])
            i += n
            if n == 0 { break }
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for x in bytes { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        d.appendBE((b << 16) | a)
        return d
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for x in d { c = crcTable[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBE(UInt32(body.count))
        var c = Data(type.utf8)
        c.append(body)
        append(c)
        appendBE(PNGWriter.crc32(c))
    }
}
