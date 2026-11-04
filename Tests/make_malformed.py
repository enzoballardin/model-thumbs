#!/usr/bin/env python3
"""Writes malformed model files into <dir>/models.

Each one crashed the parsers or read memory or files it shouldn't before the bounds
checks went in. sibling.gltf is the exception: it has to keep rendering. Run
modelthumbs-render on each one; none should die on a signal. They carry no payload.

usage: make_malformed.py <dir>
"""
import base64
import json
import os
import struct
import sys

root = sys.argv[1]
d = os.path.join(root, "models")
os.makedirs(d, exist_ok=True)
os.makedirs(os.path.join(root, "canary"), exist_ok=True)
triangle = struct.pack("<9f", 0, 0, 0, 1, 0, 0, 0, 1, 0)
for path in (os.path.join(root, "canary", "outside.bin"), os.path.join(d, "beside.bin")):
    with open(path, "wb") as f:
        f.write(triangle)


def gltf(view, accessor, uri=None):
    embedded = "data:application/octet-stream;base64," + base64.b64encode(b"\0" * 64).decode()
    return {"asset": {"version": "2.0"}, "buffers": [{"uri": uri or embedded, "byteLength": 64}],
            "bufferViews": [view], "accessors": [accessor],
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}],
            "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}


def write_json(name, value):
    with open(os.path.join(d, name), "w") as f:
        json.dump(value, f)


vec3 = {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}
plain_view = {"buffer": 0, "byteOffset": 0, "byteLength": 36}
write_json("negoffset.gltf", gltf({"buffer": 0, "byteOffset": -50000000, "byteLength": 36}, vec3))
write_json("negstride.gltf", gltf({"buffer": 0, "byteOffset": 0, "byteLength": 36, "byteStride": -5000000}, vec3))
write_json("scalarpos.gltf", gltf({"buffer": 0, "byteOffset": 60, "byteLength": 4},
                                  {"bufferView": 0, "componentType": 5126, "count": 1, "type": "SCALAR"}))
write_json("traversal.gltf", gltf(plain_view, vec3, uri="../canary/outside.bin"))
write_json("sibling.gltf", gltf(plain_view, vec3, uri="beside.bin"))

with open(os.path.join(d, "trunc.ply"), "w") as f:
    f.write("ply\nformat ascii 1.0\nelement vertex 2000000\nproperty float x\nproperty float y\n"
            "property float z\nend_header\n1 2 3\n")

header = (b"FIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\nWIDTH 2000000\nHEIGHT 1\n"
          b"POINTS 2000000\nDATA binary_compressed\n")
lzf = bytes([3, 1, 2, 3, 4])
with open(os.path.join(d, "shortbody.pcd"), "wb") as f:
    f.write(header + struct.pack("<II", len(lzf), 4) + lzf)

header = (b"FIELDS x y z\nSIZE -4 4 4\nTYPE F F F\nCOUNT 1000000 1 1\nWIDTH 100\nHEIGHT 1\n"
          b"POINTS 100\nDATA binary\n")
with open(os.path.join(d, "negsize.pcd"), "wb") as f:
    f.write(header + b"\0" * 4096)

# Zip entry declaring a 2 GB size for 2 bytes of data.
name = b"3D/3dmodel.model"
body = bytes([0x03, 0x00])
local = struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, 0, 8, 0, 0, 0, len(body), 0x7FFFFFFF, len(name), 0) + name + body
central = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 20, 20, 0, 8, 0, 0, 0, len(body), 0x7FFFFFFF,
                      len(name), 0, 0, 0, 0, 0, 0) + name
end = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 1, 1, len(central), len(local), 0)
with open(os.path.join(d, "bomb.3mf"), "wb") as f:
    f.write(local + central + end)
