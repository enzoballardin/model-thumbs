import Foundation

/// Autodesk Fusion designs. A .f3d is a ZIP whose geometry is in Autodesk's
/// proprietary ASM format, but it also carries rendered preview images under
/// a "Previews/" folder; we use the largest one. A .f3z is a ZIP of .f3d files
/// (a design plus its referenced components); we use the first design's preview.
public enum LoaderF3D {
    public static func thumbnail(_ data: Data, depth: Int = 0) throws -> Data {
        let zip = try ZipArchive(data)
        var best: Data? = nil
        for e in zip.entries {
            let n = e.name.lowercased()
            guard n.contains("previews/") || n.hasPrefix("preview") || n.contains("thumbnail") else { continue }
            guard let d = try? zip.extract(e), d.isPNG || d.isJPEG else { continue }
            if best == nil || d.count > best!.count { best = d }
        }
        if let img = best { return img }

        // .f3z: open the nested designs, largest first (usually the top-level assembly).
        if depth == 0 {
            let nested = zip.entries
                .filter { $0.name.lowercased().hasSuffix(".f3d") }
                .sorted { $0.uncompressedSize > $1.uncompressedSize }
            for e in nested {
                if let inner = try? zip.extract(e), let img = try? thumbnail(inner, depth: 1) { return img }
            }
        }
        throw ModelError.unsupported("no preview image in Fusion file")
    }
}
