// Tessellates STEP / IGES / BREP files with OpenCASCADE for thumbnail rendering.

#include "mt_cad.h"

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <vector>

#include <Standard_Failure.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <STEPControl_Reader.hxx>
#include <IGESControl_Reader.hxx>
#include <Interface_Static.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopLoc_Location.hxx>
#include <Poly_Triangulation.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>

static void silence() {
    static bool done = false;
    if (done) return;
    done = true;
    const Handle(Message_Messenger) &m = Message::DefaultMessenger();
    // Remove console printers so OCCT doesn't spam the system log.
    m->RemovePrinters(STANDARD_TYPE(Message_PrinterOStream));
}

static void setError(MTCadMesh *out, const char *msg) {
    std::snprintf(out->error, sizeof(out->error), "%s", msg);
}

static bool readShape(const char *path, int kind, TopoDS_Shape &shape, MTCadMesh *out) {
    if (kind == 0) {
        STEPControl_Reader reader;
        if (reader.ReadFile(path) != IFSelect_RetDone) { setError(out, "STEP read failed"); return false; }
        reader.TransferRoots();
        shape = reader.OneShape();
    } else if (kind == 1) {
        IGESControl_Reader reader;
        if (reader.ReadFile(path) != IFSelect_RetDone) { setError(out, "IGES read failed"); return false; }
        reader.TransferRoots();
        shape = reader.OneShape();
    } else {
        BRep_Builder builder;
        if (!BRepTools::Read(shape, path, builder)) { setError(out, "BREP read failed"); return false; }
    }
    if (shape.IsNull()) { setError(out, "no shape"); return false; }
    return true;
}

extern "C" int mt_cad_load(const char *path, int kind, MTCadMesh *out) {
    std::memset(out, 0, sizeof(*out));
    silence();
    try {
        TopoDS_Shape shape;
        if (!readShape(path, kind, shape, out)) return 1;

        Bnd_Box box;
        BRepBndLib::Add(shape, box);
        if (box.IsVoid()) { setError(out, "empty bounds"); return 1; }
        double x0, y0, z0, x1, y1, z1;
        box.Get(x0, y0, z0, x1, y1, z1);
        double dx = x1 - x0, dy = y1 - y0, dz = z1 - z0;
        double diag = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (!(diag > 0)) diag = 1;

        // Coarse tessellation: plenty for a thumbnail, and fast.
        BRepMesh_IncrementalMesh mesher(shape, diag * 0.002, Standard_False, 0.35, Standard_True);
        (void)mesher;

        std::vector<float> pos;
        std::vector<unsigned int> idx;
        for (TopExp_Explorer ex(shape, TopAbs_FACE); ex.More(); ex.Next()) {
            const TopoDS_Face &face = TopoDS::Face(ex.Current());
            TopLoc_Location loc;
            Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
            if (tri.IsNull()) continue;
            const gp_Trsf trsf = loc.Transformation();
            const unsigned int base = (unsigned int)(pos.size() / 3);
            const int nn = tri->NbNodes();
            for (int i = 1; i <= nn; ++i) {
                gp_Pnt p = tri->Node(i).Transformed(trsf);
                pos.push_back((float)p.X());
                pos.push_back((float)p.Y());
                pos.push_back((float)p.Z());
            }
            const bool reversed = face.Orientation() == TopAbs_REVERSED;
            const int nt = tri->NbTriangles();
            for (int i = 1; i <= nt; ++i) {
                int a, b, c;
                tri->Triangle(i).Get(a, b, c);
                if (reversed) { int t = b; b = c; c = t; }
                if (a < 1 || b < 1 || c < 1 || a > nn || b > nn || c > nn) continue;
                idx.push_back(base + a - 1);
                idx.push_back(base + b - 1);
                idx.push_back(base + c - 1);
            }
        }
        if (idx.empty()) { setError(out, "no triangles"); return 1; }

        out->vertexCount = (int)(pos.size() / 3);
        out->indexCount = (int)idx.size();
        out->positions = (float *)std::malloc(pos.size() * sizeof(float));
        out->indices = (unsigned int *)std::malloc(idx.size() * sizeof(unsigned int));
        if (!out->positions || !out->indices) { mt_cad_free(out); setError(out, "out of memory"); return 1; }
        std::memcpy(out->positions, pos.data(), pos.size() * sizeof(float));
        std::memcpy(out->indices, idx.data(), idx.size() * sizeof(unsigned int));
        return 0;
    } catch (const Standard_Failure &e) {
        setError(out, e.GetMessageString() ? e.GetMessageString() : "OpenCASCADE exception");
    } catch (...) {
        setError(out, "unknown exception");
    }
    return 1;
}

extern "C" void mt_cad_free(MTCadMesh *mesh) {
    if (!mesh) return;
    std::free(mesh->positions);
    std::free(mesh->indices);
    mesh->positions = nullptr;
    mesh->indices = nullptr;
    mesh->vertexCount = 0;
    mesh->indexCount = 0;
}
