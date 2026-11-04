import Foundation
import UniformTypeIdentifiers

// Prints the type identifier macOS currently associates with each file extension
// given on the command line, skipping dynamic (dyn.*) and generic types.
// The build script adds these to the extension's supported types so it also
// covers identifiers declared by slicers or CAD apps you have installed.

let generic: Set<String> = [
    "public.data", "public.item", "public.content", "public.text", "public.plain-text",
    "public.utf8-plain-text", "public.source-code", "public.composite-content", "public.archive",
    "public.zip-archive", "public.xml", "public.json", "public.image", "public.3d-content",
    "public.executable", "public.script", "public.shell-script", "public.database",
]

var seen = Set<String>()
for ext in CommandLine.arguments.dropFirst() {
    for t in UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil) {
        let id = t.identifier
        if id.hasPrefix("dyn.") || generic.contains(id) || seen.contains(id) { continue }
        // Never take over thumbnails of unrelated media that share an extension (e.g. Kodak .pcd).
        if t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .audio) { continue }
        seen.insert(id)
        print("\(ext)\t\(id)")
    }
}
