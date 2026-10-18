#!/usr/bin/env python3
"""Copy helper executables and their Homebrew dylib closure into an app bundle.

Usage: bundle_helpers.py <Contents/Helpers dir> <Contents/Resources/Licenses dir> <binary>...

- binaries go to Helpers/, dylibs to Helpers/lib/
- every Homebrew/@rpath reference is rewritten to @loader_path, Homebrew LC_RPATHs are removed
- every touched Mach-O is ad-hoc re-signed (install_name_tool invalidates signatures)
- licence files of every Homebrew package involved are copied to the licences folder
"""
import os
import re
import shutil
import subprocess
import sys

BREW_PREFIXES = ("/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def deps(path):
    out = run("otool", "-L", path).splitlines()[1:]
    return [line.strip().split(" (")[0] for line in out if line.strip()]


def rpaths(path):
    out = run("otool", "-l", path).splitlines()
    found = []
    for i, line in enumerate(out):
        if "cmd LC_RPATH" in line:
            for j in range(i, min(i + 4, len(out))):
                m = re.search(r"path (.+?) \(offset", out[j])
                if m:
                    found.append(m.group(1))
    return found


def resolve(ref, referrer):
    if ref.startswith(BREW_PREFIXES):
        return os.path.realpath(ref)
    if ref.startswith("@rpath/"):
        name = ref[len("@rpath/"):]
        for rp in rpaths(referrer):
            base = rp.replace("@loader_path", os.path.dirname(os.path.realpath(referrer)))
            base = base.replace("@executable_path", os.path.dirname(os.path.realpath(referrer)))
            cand = os.path.join(base, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
    return None


def cellar_package(path):
    m = re.search(r"/Cellar/([^/]+)/([^/]+)/", path)
    return (m.group(1), m.group(2)) if m else None


def main():
    helpers, licenses, binaries = sys.argv[1], sys.argv[2], sys.argv[3:]
    lib_dir = os.path.join(helpers, "lib")
    os.makedirs(lib_dir, exist_ok=True)
    os.makedirs(licenses, exist_ok=True)
    packages = {}
    queue = []  # (source real path, destination path, is_binary)
    for b in binaries:
        real = os.path.realpath(b)
        queue.append((real, os.path.join(helpers, os.path.basename(b)), True))
    copied = {}
    while queue:
        src, dst, is_bin = queue.pop()
        if dst in copied:
            continue
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755)
        copied[dst] = src
        pkg = cellar_package(src)
        if pkg:
            packages[pkg[0]] = pkg
        for ref in deps(src):
            target = resolve(ref, src)
            if not target:
                continue
            name = os.path.basename(ref)
            new_dst = os.path.join(lib_dir, name)
            loader = "@loader_path/lib/" if is_bin else "@loader_path/"
            subprocess.run(["install_name_tool", "-change", ref, loader + name, dst], check=True, capture_output=True)
            if new_dst not in copied:
                queue.append((target, new_dst, False))
        if not is_bin:
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + os.path.basename(dst), dst], check=True, capture_output=True)
        for rp in rpaths(dst):
            if rp.startswith(BREW_PREFIXES) or rp.startswith("@loader_path/../lib"):
                subprocess.run(["install_name_tool", "-delete_rpath", rp, dst], check=False, capture_output=True)
    for path in copied:
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", path], check=True, capture_output=True)
    # Licences.
    for name, (pkg, version) in sorted(packages.items()):
        root = None
        for prefix in ("/opt/homebrew/Cellar", "/usr/local/Cellar"):
            cand = os.path.join(prefix, pkg, version)
            if os.path.isdir(cand):
                root = cand
        if not root:
            continue
        dest = os.path.join(licenses, f"{pkg}-{version}")
        os.makedirs(dest, exist_ok=True)
        for entry in os.listdir(root):
            if re.match(r"(?i)^(licen[cs]e|copying|copyright|notice|patents|authors)", entry):
                src = os.path.join(root, entry)
                if os.path.isfile(src):
                    shutil.copy2(src, os.path.join(dest, entry))
        share = os.path.join(root, "share", "doc", pkg)
        if os.path.isdir(share):
            for entry in os.listdir(share):
                if re.match(r"(?i)^(licen[cs]e|copying|copyright|notice|patents)", entry):
                    src = os.path.join(share, entry)
                    if os.path.isfile(src):
                        shutil.copy2(src, os.path.join(dest, entry))
    # Verify nothing still points into Homebrew.
    leaks = []
    for path in copied:
        for ref in deps(path):
            if ref.startswith(BREW_PREFIXES) or ref.startswith("@rpath/"):
                leaks.append(f"{os.path.basename(path)} -> {ref}")
    for name, (pkg, version) in sorted(packages.items()):
        print(f"package {pkg} {version}")
    print(f"bundled {len(copied)} Mach-O files")
    if leaks:
        print("UNRESOLVED REFERENCES:\n  " + "\n  ".join(leaks))
        sys.exit(1)


if __name__ == "__main__":
    main()
