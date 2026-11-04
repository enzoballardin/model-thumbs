import Foundation

/// Picks a loader from the file extension (falling back to content sniffing).
public enum ModelLoader {
    public struct Options {
        /// For 3MF: use the slicer's embedded preview image when present.
        public var preferEmbeddedThumbnail = true
        public init() {}
    }

    /// Hook for formats implemented outside the portable core (STEP/IGES via OpenCASCADE).
    public static var cadLoader: ((URL, String) throws -> Mesh)? = nil

    public static let meshExtensions: Set<String> = ["3mf", "amf", "obj", "ply", "off", "glb", "gltf",
                                                     "xyz", "pts", "asc", "stl"]
    public static let cadExtensions: Set<String> = ["step", "stp", "p21", "iges", "igs", "brep", "brp"]
    public static let imageExtensions: Set<String> = ["gcode", "gco", "bgcode", "f3d", "f3z"]

    public static func load(_ url: URL, options: Options = Options()) throws -> LoadResult {
        let ext = url.pathExtension.lowercased()
        if cadExtensions.contains(ext) {
            guard let cad = cadLoader else { throw ModelError.unsupported("CAD support not built in") }
            return .mesh(try cad(url, ext))
        }
        let data = try Data.readModelFile(url)
        switch ext {
        case "3mf":
            let zip = try ZipArchive(data)
            if options.preferEmbeddedThumbnail, let img = Loader3MF.embeddedThumbnail(zip) { return .image(img) }
            do { return .mesh(try Loader3MF.loadMesh(zip)) }
            catch {
                if let img = Loader3MF.embeddedThumbnail(zip) { return .image(img) }
                throw error
            }
        case "amf": return .mesh(try LoaderAMF.load(data))
        case "obj":
            var m = try LoaderText.loadOBJ(data); m.convertYUpToZUp(); return .mesh(m)
        case "ply": return .mesh(try LoaderPLY.load(data))
        case "off": return .mesh(try LoaderText.loadOFF(data))
        case "glb", "gltf": return .mesh(try LoaderGLTF.load(data, url: url))
        case "xyz", "pts", "asc": return .mesh(try LoaderText.loadPointCloud(data))
        case "stl": return .mesh(try LoaderSTL.load(data))
        case "gcode", "gco", "bgcode": return .image(try LoaderGCode.thumbnail(data))
        case "f3d", "f3z": return .image(try LoaderF3D.thumbnail(data))

        // Embedded previews
        case "ufp": return .image(try LoaderPreviews.zipImage(data, hints: ["thumbnail", "metadata/"]))
        case "fcstd": return .image(try LoaderPreviews.zipImage(data, hints: ["thumbnails/", "thumbnail"]))
        case "sl1", "sl1s": return .image(try LoaderPreviews.zipImage(data, hints: ["thumbnail"]))
        case "lbrn", "lbrn2": return .image(try LoaderPreviews.lightBurn(data))
        case "ctb", "cbddlp", "photon", "phz": return .image(try LoaderPreviews.chitubox(data))
        case "goo", "prz": return .image(try LoaderPreviews.goo(data))
        case "pws", "pw0", "pwx", "dlp", "dl2p", "pwmx", "pmx2", "pwmb", "px6s", "pwmo", "pm3n", "pm4n",
             "pwms", "pwma", "pmsq", "pm3", "pm3m", "pm3r", "pm5", "pm5s", "m5sp", "pwc":
            return .image(try LoaderPreviews.anycubic(data))
        case "3dm": return .image(try LoaderPreviews.rhino(data))
        case "blend", "blend1": return .image(try LoaderPreviews.blender(data))
        case "skp": return .image(try LoaderPreviews.sketchUp(data))
        case "sldprt", "sldasm", "slddrw", "ipt", "iam", "ipn", "idw":
            return .image(try LoaderPreviews.embedded(data))

        // Rendered
        case "e57": return .mesh(try LoaderE57.load(data))
        case "pcd": return .mesh(try LoaderPointClouds.loadPCD(data))
        case "las": return .mesh(try LoaderPointClouds.loadLAS(data))
        case "dae": return .mesh(try LoaderDAE.load(data))
        case "wrl", "vrml": return .mesh(try LoaderVRML.loadVRML(data))
        case "x3d": return .mesh(try LoaderVRML.loadX3D(data))
        case "3ds": return .mesh(try Loader3DS.load(data))
        default:
            throw ModelError.unsupported("extension .\(ext)")
        }
    }
}

/// STL (binary + ASCII). Not registered with Quick Look by default because macOS
/// already draws STL thumbnails, but handy for the command-line renderer.
public enum LoaderSTL {
    public static func load(_ data: Data) throws -> Mesh {
        if data.count >= 84 {
            let r = BinaryReader(data)
            let n = Int(r.peekU32(at: 80) ?? 0)
            if 84 + n * 50 == data.count {
                var m = Mesh()
                m.positions.reserveCapacity(n * 9)
                m.indices.reserveCapacity(n * 3)
                data.withUnsafeBytes { raw in
                    for t in 0..<n {
                        let base = 84 + t * 50 + 12
                        for v in 0..<3 {
                            for c in 0..<3 {
                                m.positions.append(raw.loadUnaligned(fromByteOffset: base + v * 12 + c * 4, as: Float.self))
                            }
                        }
                        let i = UInt32(t * 3)
                        m.addTriangle(i, i + 1, i + 2)
                    }
                }
                return m
            }
        }
        // ASCII
        let b = TextBuffer(data)
        var m = Mesh()
        var pos = 0, end = 0
        var count = 0
        while pos < b.count {
            b.skipSpaces(&pos)
            while pos < b.count && (b[pos] == 10) { pos += 1; b.skipSpaces(&pos) }
            if b.matches("vertex", at: pos) {
                pos += 6
                var v: [Double] = [0, 0, 0]
                for k in 0..<3 { if let d = b.parseDouble(at: pos, end: &end) { v[k] = d; pos = end } }
                m.addVertex(Float(v[0]), Float(v[1]), Float(v[2]))
                count += 1
                if count % 3 == 0 { let i = UInt32(count - 3); m.addTriangle(i, i + 1, i + 2) }
            }
            b.skipToNextLine(&pos)
        }
        if m.isEmpty { throw ModelError.empty }
        return m
    }
}
