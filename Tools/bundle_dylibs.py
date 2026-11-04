#!/usr/bin/env python3
"""Copy non-system dylibs a Mach-O binary depends on (recursively) into a
Frameworks folder and rewrite references to @rpath, so the bundle is
self-contained and works inside the Quick Look sandbox.

usage: bundle_dylibs.py <binary> <frameworks_dir> <rpath_from_binary> [extra binaries...]
  rpath_from_binary: e.g. @executable_path/../Frameworks
Extra binaries are rewritten to use the same bundled libraries (their rpath is
passed as "binary=rpath").
"""
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def deps(path):
    out = run("otool", "-L", path).splitlines()[1:]
    result = []
    for line in out:
        line = line.strip()
        if not line:
            continue
        result.append(line.split(" (compatibility")[0].strip())
    return result


def install_id(path):
    out = run("otool", "-D", path).splitlines()
    return out[1].strip() if len(out) > 1 else None


def rpaths(path):
    out = run("otool", "-l", path).splitlines()
    found = []
    for i, line in enumerate(out):
        if "LC_RPATH" in line:
            for j in range(i + 1, min(i + 4, len(out))):
                s = out[j].strip()
                if s.startswith("path "):
                    found.append(s[5:].split(" (offset")[0])
                    break
    return found


def resolve(ref, referrer, search_dirs):
    if ref.startswith(SYSTEM_PREFIXES):
        return None
    if ref.startswith("@rpath/"):
        name = ref[len("@rpath/"):]
        base = os.path.dirname(os.path.realpath(referrer))
        cands = []
        for rp in rpaths(referrer):
            rp = rp.replace("@loader_path", base).replace("@executable_path", base)
            cands.append(os.path.join(rp, name))
        cands += [os.path.join(d, name) for d in search_dirs]
        for c in cands:
            if os.path.exists(c):
                return os.path.realpath(c)
        return None
    if ref.startswith("@loader_path/"):
        c = os.path.join(os.path.dirname(os.path.realpath(referrer)), ref[len("@loader_path/"):])
        return os.path.realpath(c) if os.path.exists(c) else None
    if ref.startswith("@executable_path/"):
        return None
    return os.path.realpath(ref) if os.path.exists(ref) else None


def main():
    binary, fw, binary_rpath = sys.argv[1], sys.argv[2], sys.argv[3]
    extras = [a.split("=", 1) for a in sys.argv[4:]]
    os.makedirs(fw, exist_ok=True)

    search_dirs = set()
    copied = {}  # real source path -> bundled basename
    queue = []

    def schedule(ref, referrer):
        real = resolve(ref, referrer, search_dirs)
        if real is None:
            return None
        search_dirs.add(os.path.dirname(ref) if ref.startswith("/") else os.path.dirname(real))
        if real not in copied:
            name = os.path.basename(ref)
            dst = os.path.join(fw, name)
            shutil.copy2(real, dst)
            os.chmod(dst, 0o755)
            copied[real] = name
            queue.append((dst, real))
        return copied[real]

    def rewrite(target, original):
        for ref in deps(target):
            if ref == install_id(target):
                continue
            name = schedule(ref, original)
            if name:
                run("install_name_tool", "-change", ref, "@rpath/" + name, target)

    # Main binaries
    for b, rp in [(binary, binary_rpath)] + extras:
        rewrite(b, b)
        if rp not in rpaths(b):
            run("install_name_tool", "-add_rpath", rp, b)

    # Libraries (breadth-first)
    while queue:
        dst, real = queue.pop(0)
        run("install_name_tool", "-id", "@rpath/" + os.path.basename(dst), dst)
        rewrite(dst, real)
        for rp in rpaths(dst):
            try:
                run("install_name_tool", "-delete_rpath", rp, dst)
            except subprocess.CalledProcessError:
                pass
        run("install_name_tool", "-add_rpath", "@loader_path", dst)

    print(f"bundled {len(copied)} libraries")


if __name__ == "__main__":
    main()
