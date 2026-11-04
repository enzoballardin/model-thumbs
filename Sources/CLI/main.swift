import Foundation

// modelthumbs-render <input> <output.png> [size] [--model]
// Renders a thumbnail exactly like the Quick Look extension does. Useful for
// testing a file that shows a blank icon in Finder.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: modelthumbs-render <input> <output.png> [size] [--model]\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let size = args.count > 3 ? Int(args[3]) ?? 512 : 512
var options = ModelLoader.Options()
if args.contains("--model") { options.preferEmbeddedThumbnail = false }

#if MT_HAS_OCCT
ModelLoader.cadLoader = CADLoader.load
#endif

let t0 = Date()
do {
    let result = try ModelLoader.load(input, options: options)
    switch result {
    case .image(let data):
        try data.write(to: output)
        print("embedded image (\(data.count) bytes)")
    case .mesh(let mesh):
        let t1 = Date()
        var ro = RenderOptions()
        ro.size = size
        ro.supersample = size <= 256 ? 3 : 2
        let img = Renderer.render(mesh, options: ro)
        try PNGWriter.encode(img).write(to: output)
        print(String(format: "%d verts, %d tris; load %.2fs, render %.2fs",
                     mesh.vertexCount, mesh.triangleCount, t1.timeIntervalSince(t0), Date().timeIntervalSince(t1)))
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
