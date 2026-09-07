#!/usr/bin/env python3
"""Turn the runtime closure of the Nix-built GnuCash into a self-contained,
relocatable GnuCash.app, the way gtk-mac-bundler does for a jhbuild prefix.

Layout (what GnuCash's own macOS support expects: with a bundle id present,
gtkosx_application_get_resource_path() -> Contents/Resources becomes
GNC_HOME, and etc/gnucash/environment supplies everything else relative to
it):

  GnuCash.app/Contents/MacOS/GnuCash          the real gnucash binary
  GnuCash.app/Contents/Resources/{bin,lib,libexec,share,etc}
                                              every needed store path merged
                                              into one prefix

All Mach-O references to /nix/store are rewritten to @rpath/<path under lib>
with one @loader_path-relative LC_RPATH per binary, so nothing depends on
where the bundle sits.  Files that list dylib paths (gdk-pixbuf and GTK
input-method caches) use @loader_path entries, which dyld expands in
dlopen() relative to the library that loads them.
"""

import argparse
import filecmp
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

STORE = "/nix/store"
STORE_RE = re.compile(r"^/nix/store/([^/]+)(?:/(.*))?$")

# Store paths that are in the closure only through build-time leftovers
# (Python's static libpython references the SDK and compiler) or that only
# provide build tools.  Matched against the name after the hash.
EXCLUDED_PACKAGES = re.compile(
    r"^(llvm|clang|clang-wrapper|apple-sdk|cctools|cctools-binutils|ld64|"
    r"compiler-rt-libc|xcbuild|libSystem-B|expand-response-params|"
    r"gobject-introspection-wrapped|cups-headers|"
    r"xorgproto|bash|coreutils|gawk|gnugrep|fonts\.conf)(-|$)"
    # Perl and Finance::Quote are deliberately not bundled: quote sources
    # change constantly, so like the official app we use the system perl and
    # let the user keep Finance::Quote current (gnc-fq-update / cpan).
    r"|^perl-\d|^perl5\."
)
EXCLUDED_OUTPUT_SUFFIXES = ("-dev", "-man", "-doc", "-devdoc", "-info", "-static")
# nixpkgs' darwin libiconv is Apple's own (it dlopens its converter modules
# from a compiled-in store path); macOS ships the identical library, so
# link against the system copy instead of bundling it.
SYSTEM_LIBRARY_PACKAGES = ("libiconv-115",)

# Only these packages contribute programs; everything else's bin/ is build
# tooling we don't ship.  (python3-…-env's bin holds store-path wrappers.)
BIN_PACKAGES = re.compile(r"^(gnucash|python3|aqbanking|gwenhywfar|libchipcard)-\d(?!.*-env$)")
LIBEXEC_PACKAGES = re.compile(r"^(webkitgtk|gstreamer|gst-plugins-base)(-|$)")
ETC_PACKAGES = re.compile(r"^(gnucash|fontconfig|gtk\+3|openssl)(-|$)")

SKIP_DIRS = {
    "include", "nix-support", "lib/pkgconfig", "lib/cmake", "share/pkgconfig",
    "share/man", "share/gtk-doc", "share/gir-1.0", "share/vala", "share/aclocal",
    "share/info", "share/emacs", "share/bash-completion", "share/zsh", "share/fish",
    "share/gettext", "share/gettext-1.0", "share/cmake", "share/thumbnailers",
    "lib/python3.14/config-3.14-darwin", "lib/python3.14/test",
    "lib/python3.14/idlelib", "lib/python3.14/turtledemo", "lib/python3.14/tkinter",
    "lib/python3.14/ensurepip",
}
SKIP_SUFFIXES = (".a", ".la", ".pyc.orig")
# gnucash-docs: keep the English manuals only (each language is ~25 MB)
DOC_LANG_KEEP = {"C"}

# Files regenerated after the merge, so conflicts between packages are fine.
REGENERATED = {
    "lib/gdk-pixbuf-2.0/2.10.0/loaders.cache",
    "lib/gtk-3.0/3.0.0/immodules.cache",
    "lib/gio/modules/giomodule.cache",
    "share/glib-2.0/schemas/gschemas.compiled",
    "share/mime/mime.cache",
    "share/applications/mimeinfo.cache",
    "etc/fonts/fonts.conf",
}


def log(*a):
    print("bundle:", *a, file=sys.stderr, flush=True)


def run(*cmd, check=True, capture=False):
    return subprocess.run(cmd, check=check, text=True,
                          capture_output=capture)


def store_name(path):
    """/nix/store/<hash>-<name> -> <name>"""
    return os.path.basename(path).split("-", 1)[1]


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


class Bundler:
    def __init__(self, gnucash, closure_file, app, version, icns, bundle_id):
        self.gnucash = gnucash
        self.app = Path(app)
        self.res = self.app / "Contents" / "Resources"
        self.version = version
        self.icns = icns
        self.bundle_id = bundle_id
        paths = [l.strip() for l in open(closure_file) if l.strip()]
        self.bundled = {}
        for p in paths:
            name = store_name(p)
            if EXCLUDED_PACKAGES.match(name) or name.endswith(EXCLUDED_OUTPUT_SUFFIXES) \
                    or name.startswith(SYSTEM_LIBRARY_PACKAGES):
                log("excluding", name)
                continue
            self.bundled[os.path.basename(p)] = p
        self.conflicts = []
        self.relocated = {}      # (store base, path in package) -> path in bundle
        self.missing_refs = {}

    # ------------------------------------------------------------ merging
    def want(self, name, sub):
        """Should file <sub> of package <name> be copied?"""
        top = sub.split("/", 1)[0]
        if top == "bin" and not BIN_PACKAGES.match(name):
            return False
        if top == "libexec" and not LIBEXEC_PACKAGES.match(name):
            return False
        if top == "etc" and not ETC_PACKAGES.match(name):
            return False
        if top not in ("bin", "lib", "libexec", "share", "etc"):
            return False
        for d in SKIP_DIRS:
            if sub == d or sub.startswith(d + "/"):
                return False
        if sub.endswith(SKIP_SUFFIXES):
            return False
        if sub.startswith("share/doc/"):
            if not sub.startswith("share/doc/gnucash-docs/"):
                return False
            parts = sub.split("/")
            if len(parts) > 3 and parts[3] not in DOC_LANG_KEEP:
                return False
        return True

    def target_for_store(self, real):
        """Map an absolute store file to its bundle location, if bundled."""
        m = STORE_RE.match(real)
        if not m:
            return None
        base, sub = m.group(1), m.group(2) or ""
        if base not in self.bundled:
            return None
        return self.res / sub

    def merge(self):
        # deterministic order by package name, so duplicate libraries
        # (e.g. two builds of libwebp in the closure) resolve the same way
        for store in sorted(self.bundled.values(), key=lambda p: (store_name(p), p)):
            name = store_name(store)
            for root, dirs, files in os.walk(store):
                rel_root = os.path.relpath(root, store)
                rel_root = "" if rel_root == "." else rel_root
                dirs[:] = [d for d in dirs
                           if self.want(name, os.path.join(rel_root, d) if rel_root else d)]
                for f in files + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
                    sub = os.path.join(rel_root, f) if rel_root else f
                    if self.want(name, sub):
                        self.place(os.path.join(root, f), self.res / sub, sub,
                                   os.path.basename(store))
                # symlinked directories were handled above as entries
                dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]

    def place(self, src, dst, sub, base):
        dst.parent.mkdir(parents=True, exist_ok=True)
        if os.path.islink(src):
            real = os.path.realpath(src)
            if not os.path.exists(real):
                return
            inside = self.target_for_store(real)
            if inside is not None:
                if os.path.isdir(real) or inside == dst:
                    # the target is merged at that very place anyway
                    return
                rel = os.path.relpath(inside, dst.parent)
                if dst.is_symlink() or dst.exists():
                    if dst.is_symlink() and os.readlink(dst) == rel:
                        return
                    if sub in REGENERATED:
                        dst.unlink()
                    else:
                        self.conflicts.append((sub, src))
                        return
                os.symlink(rel, dst)
                return
            if os.path.isdir(real):
                shutil.copytree(real, dst, symlinks=False, dirs_exist_ok=True)
                return
            src = real
        if dst.exists() or dst.is_symlink():
            if dst.is_file() and not dst.is_symlink() and filecmp.cmp(src, dst, shallow=False):
                return
            if sub in REGENERATED:
                dst.unlink()
            elif is_macho(src):
                # Same file name, different library (e.g. GNU and Apple
                # libiconv both install libiconv.2.dylib): keep this copy
                # aside and point its dependents at it (see map_ref).
                top, rest = sub.split("/", 1)
                alt_sub = f"{top}/.alt/{base}/{rest}"
                self.relocated[(base, sub)] = alt_sub
                dst = self.res / alt_sub
                dst.parent.mkdir(parents=True, exist_ok=True)
            else:
                # keep the first copy; the report lists what was skipped
                self.conflicts.append((sub, src))
                return
        shutil.copyfile(src, dst)
        os.chmod(dst, os.stat(src).st_mode | stat.S_IWUSR)

    # ------------------------------------------------------- wrappers etc.
    def unwrap_programs(self):
        """nixpkgs wrappers embed store paths; the environment file replaces
        them, so ship the wrapped programs under their real names."""
        bindir = self.res / "bin"
        for wrapped in sorted(bindir.glob(".*-wrapped")):
            real = bindir / wrapped.name[1:-len("-wrapped")]
            if real.exists() or real.is_symlink():
                real.unlink()
            wrapped.rename(real)
            log("unwrapped", real.name)

    def fix_shebangs(self):
        for d in ("bin", "libexec"):
            for p in (self.res / d).rglob("*"):
                if not p.is_file() or p.is_symlink():
                    continue
                try:
                    with open(p, "rb") as f:
                        head = f.read(200)
                except OSError:
                    continue
                if not head.startswith(b"#!/nix/store/"):
                    continue
                line = head.partition(b"\n")[0]
                interp = line[2:].split()[0].decode()
                prog = os.path.basename(interp)
                new = "/bin/sh" if prog == "sh" else "/bin/bash" if prog == "bash" \
                    else f"/usr/bin/env {prog}"
                data = open(p, "rb").read()
                data = b"#!" + new.encode() + data[len(line):]
                open(p, "wb").write(data)
                log("shebang", p.relative_to(self.res), "->", new)

    # ------------------------------------------------------------- Mach-O
    def macho_files(self):
        for p in self.app.rglob("*"):
            if p.is_file() and not p.is_symlink() and is_macho(p):
                yield p

    def parse_load_commands(self, path):
        out = run("otool", "-l", str(path), capture=True).stdout
        ident, deps, rpaths = None, [], []
        cmd = None
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("cmd "):
                cmd = line.split()[1]
            elif line.startswith("name ") and cmd in ("LC_ID_DYLIB", "LC_LOAD_DYLIB",
                                                       "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                                                       "LC_LOAD_UPWARD_DYLIB"):
                name = line[5:].rsplit(" (offset", 1)[0]
                if cmd == "LC_ID_DYLIB":
                    ident = name
                else:
                    deps.append(name)
            elif line.startswith("path ") and cmd == "LC_RPATH":
                rpaths.append(line[5:].rsplit(" (offset", 1)[0])
        return ident, deps, rpaths

    def map_ref(self, ref, at):
        m = STORE_RE.match(ref)
        if not m:
            return ref
        base, sub = m.group(1), m.group(2) or ""
        if store_name(base).startswith(SYSTEM_LIBRARY_PACKAGES):
            return "/usr/lib/" + os.path.basename(sub)
        if base not in self.bundled:
            self.missing_refs.setdefault(ref, set()).add(str(at))
            return ref
        sub = self.relocated.get((base, sub), sub)
        if sub.startswith("lib/"):
            return "@rpath/" + sub[4:]
        return "@rpath/../" + sub

    def rewrite_macho(self):
        libdir = self.res / "lib"
        for p in list(self.macho_files()):
            ident, deps, rpaths = self.parse_load_commands(p)
            args = []
            rel_lib = os.path.relpath(libdir, p.parent)
            wanted_rpath = "@loader_path" + ("" if rel_lib == "." else "/" + rel_lib)
            if ident is not None:
                new_id = self.map_ref(ident, p)
                if new_id == ident and ident.startswith("/"):
                    # id not in store form (e.g. build dir); derive from location
                    sub = p.relative_to(self.res).as_posix()
                    new_id = "@rpath/" + sub[4:] if sub.startswith("lib/") else "@rpath/../" + sub
                if new_id != ident:
                    args += ["-id", new_id]
            for d in deps:
                nd = self.map_ref(d, p)
                if nd != d:
                    args += ["-change", d, nd]
            for r in rpaths:
                if r.startswith(STORE) or r == wanted_rpath:
                    args += ["-delete_rpath", r]
            if wanted_rpath in rpaths:
                pass
            args += ["-add_rpath", wanted_rpath]
            os.chmod(p, os.stat(p).st_mode | stat.S_IWUSR)
            res = run("install_name_tool", *args, str(p), check=False, capture=True)
            if res.returncode != 0:
                raise SystemExit(f"install_name_tool failed on {p}:\n{res.stderr}")

    def fix_typelibs(self):
        """GObject-introspection typelibs record the absolute path of the
        shared library they bind (the python plugin's `import gi` would
        otherwise dlopen a second GTK stack from the store). Replace the
        store paths in place with @loader_path ones (relative to
        libgirepository, which is what dlopens them), NUL-padded so the
        string table offsets stay valid."""
        lib = self.res / "lib"
        for tl in sorted((lib / "girepository-1.0").glob("*.typelib")):
            data = bytearray(tl.read_bytes())
            changed = False
            for m in list(re.finditer(rb"/nix/store/[^\0]+", bytes(data))):
                old = m.group(0).decode()
                parts = []
                for ref in old.split(","):
                    mapped = self.map_ref(ref, tl)
                    parts.append(mapped.replace("@rpath/", "@loader_path/", 1))
                new = ",".join(parts).encode()
                if len(new) > len(old):
                    raise SystemExit(f"typelib path too long to relocate: {tl} {old}")
                data[m.start():m.end()] = new.ljust(len(old), b"\0")
                changed = True
            if changed:
                tl.write_bytes(bytes(data))

    # --------------------------------------------------------------- caches
    def regenerate_caches(self):
        lib = self.res / "lib"
        # Module caches list dylib paths. Rather than dlopen-ing relocated
        # modules inside the build sandbox, take the entries every bundled
        # package already generated for its own modules and point them at
        # the merged location: dyld expands @loader_path in dlopen()
        # relative to the library doing the loading (libgdk_pixbuf / libgtk
        # in Resources/lib), so the entries stay valid wherever the app is.
        for cache_rel, moddir_rel in (("lib/gdk-pixbuf-2.0/2.10.0/loaders.cache",
                                       "gdk-pixbuf-2.0/2.10.0/loaders"),
                                      ("lib/gtk-3.0/3.0.0/immodules.cache",
                                       "gtk-3.0/3.0.0/immodules")):
            entries = {}
            for store in self.bundled.values():
                cache = Path(store) / cache_rel
                if not cache.is_file():
                    continue
                for block in re.split(r"\n\s*\n", cache.read_text()):
                    lines = [l for l in block.splitlines() if not l.startswith("#")]
                    if not lines or not lines[0].startswith('"'):
                        continue
                    modpath = lines[0].strip().strip('"')
                    name = os.path.basename(modpath)
                    if not (lib / moddir_rel / name).exists():
                        continue
                    lines[0] = f'"@loader_path/{moddir_rel}/{name}"'
                    entries[name] = "\n".join(lines)
            if entries:
                # gdk-pixbuf's parser needs a blank line to close a block,
                # including the last one
                text = "# generated by bundle-app.py\n\n" + "\n\n".join(
                    entries[k] for k in sorted(entries)) + "\n\n"
                (self.res / cache_rel).write_text(text)
                log(cache_rel, "entries:", sorted(entries))
        # GIO modules (cache holds basenames only)
        gio = lib / "gio/modules"
        if gio.is_dir():
            run("gio-querymodules", str(gio))
        # GSettings schemas: gather nixpkgs' per-package schema dirs
        schemas = self.res / "share/glib-2.0/schemas"
        schemas.mkdir(parents=True, exist_ok=True)
        for d in (self.res / "share/gsettings-schemas").glob("*/glib-2.0/schemas"):
            for f in d.iterdir():
                if f.suffix in (".xml", ".override"):
                    shutil.copyfile(f, schemas / f.name)
        run("glib-compile-schemas", str(schemas))
        # MIME database and icon caches
        if (self.res / "share/mime/packages").is_dir():
            run("update-mime-database", str(self.res / "share/mime"))
        for theme in (self.res / "share/icons").glob("*"):
            if (theme / "index.theme").exists() and shutil.which("gtk-update-icon-cache"):
                run("gtk-update-icon-cache", "-q", "-t", "-f", str(theme), check=False)

    # ------------------------------------------------------ configuration
    def write_environment(self):
        env_file = self.res / "etc/gnucash/environment"
        txt = env_file.read_text()
        # anything pointing into the (merged) gnucash prefix is now GNC_HOME
        txt = re.sub(r"/nix/store/[^/;\n]+/", "{GNC_HOME}/", txt)
        # drop what gnucash's cmake appends for the bundle so we control it
        txt = re.sub(r"^(GTK_EXE_PREFIX|GIO_MODULE_DIR|GDK_PIXBUF_MODULE_FILE|FONTCONFIG_PATH|"
                     r"OFX_DTD_PATH|GNC_DBD_DIR|GTK_IM_MODULE_FILE|MARIADB_PLUGIN_DIR)=.*\n",
                     "", txt, flags=re.M)
        py = sorted((self.res / "lib").glob("python3.*"))
        pyver = py[0].name if py else "python3"
        extra = f"""
# --- added by the app bundler: everything lives under Contents/Resources
GTK_EXE_PREFIX={{GNC_HOME}}
GTK_DATA_PREFIX={{GNC_HOME}}
GTK_PATH={{GNC_HOME}}
GTK_IM_MODULE_FILE={{SYS_LIB}}/gtk-3.0/3.0.0/immodules.cache
GDK_PIXBUF_MODULE_FILE={{SYS_LIB}}/gdk-pixbuf-2.0/2.10.0/loaders.cache
GIO_MODULE_DIR={{SYS_LIB}}/gio/modules
GSETTINGS_SCHEMA_DIR={{GNC_HOME}}/share/glib-2.0/schemas
XDG_CONFIG_DIRS={{GNC_HOME}}/etc/xdg;{{XDG_CONFIG_DIRS}}
FONTCONFIG_PATH={{GNC_HOME}}/etc/fonts
FONTCONFIG_FILE={{GNC_HOME}}/etc/fonts/fonts.conf
OFX_DTD_PATH={{GNC_HOME}}/share/libofx/dtd
GNC_DBD_DIR={{SYS_LIB}}/dbd
MARIADB_PLUGIN_DIR={{SYS_LIB}}/mariadb/plugin
WEBKIT_EXEC_PATH={{GNC_HOME}}/libexec/webkit2gtk-4.1
WEBKIT_INJECTED_BUNDLE_PATH={{SYS_LIB}}/webkit2gtk-4.1/injected-bundle
WEBKIT_DISABLE_COMPOSITING_MODE=1
GST_PLUGIN_SYSTEM_PATH_1_0={{SYS_LIB}}/gstreamer-1.0
GST_PLUGIN_SCANNER={{GNC_HOME}}/libexec/gstreamer-1.0/gst-plugin-scanner
GUILE_SYSTEM_PATH={{GNC_HOME}}/share/guile/3.0
GUILE_SYSTEM_COMPILED_PATH={{SYS_LIB}}/guile/3.0/ccache
GUILE_SYSTEM_EXTENSIONS_PATH={{SYS_LIB}}/guile/3.0/extensions
GUILE_LIBS={{GNC_HOME}}/share/guile/3.0
GUILE_COMPILED_LIBS={{SYS_LIB}}/guile/3.0/ccache
PYTHONHOME={{GNC_HOME}}
PYTHONPATH={{GNC_HOME}}/lib/{pyver}/site-packages;{{PYTHONPATH}}
# Finance::Quote runs on the system perl (see gnc-fq-update), not a bundled one.
"""
        env_file.write_text(txt.rstrip("\n") + "\n" + extra)

    def write_fontconfig(self):
        etc = self.res / "etc/fonts"
        etc.mkdir(parents=True, exist_ok=True)
        (etc / "fonts.conf").write_text("""<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <description>GnuCash.app font configuration</description>
  <dir>/System/Library/Fonts</dir>
  <dir>/System/Library/Fonts/Supplemental</dir>
  <dir>/Library/Fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <dir>~/Library/Fonts</dir>
  <dir prefix="relative">../../share/fonts</dir>
  <include ignore_missing="yes">conf.d</include>
  <cachedir prefix="xdg">fontconfig</cachedir>
  <cachedir>~/.fontconfig</cachedir>
</fontconfig>
""")

    def write_bundle_files(self):
        contents = self.app / "Contents"
        macos = contents / "MacOS"
        macos.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.res / "bin/gnucash", macos / "GnuCash")
        os.chmod(macos / "GnuCash", 0o755)
        if self.icns:
            shutil.copyfile(self.icns, self.res / "gnucash.icns")
        info = {
            "CFBundleDevelopmentRegion": "English",
            "CFBundleExecutable": "GnuCash",
            "CFBundleIconFile": "gnucash.icns",
            "CFBundleIdentifier": self.bundle_id,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "GnuCash",
            "CFBundleDisplayName": "GnuCash",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": self.version,
            "CFBundleVersion": self.version,
            "CFBundleSignature": "????",
            "CFBundleDocumentTypes": [
                {"CFBundleTypeName": "GnuCash Document",
                 "CFBundleTypeExtensions": ["gnucash"],
                 "CFBundleTypeIconFile": "gnucash.icns",
                 "CFBundleTypeRole": "Editor"},
                {"CFBundleTypeName": "GnuCash Import/Export",
                 "CFBundleTypeExtensions": ["qif", "ofx", "txf"],
                 "CFBundleTypeIconFile": "gnucash.icns",
                 "CFBundleTypeRole": "Viewer"},
            ],
            "LSMinimumSystemVersion": "12.0",
            "LSApplicationCategoryType": "public.app-category.finance",
            "NSHighResolutionCapable": True,
            "NSHumanReadableCopyright": "GnuCash Contributors",
        }
        with open(contents / "Info.plist", "wb") as f:
            plistlib.dump(info, f)
        (contents / "PkgInfo").write_text("APPL????")

    # --------------------------------------------------------------- report
    def report(self):
        if self.conflicts:
            log(f"{len(self.conflicts)} files differed between packages (first copy kept):")
            for sub, src in self.conflicts[:200]:
                m = STORE_RE.match(src)
                log("  ", sub, "<-", m.group(1) if m else src)
        if self.missing_refs:
            log("MACH-O REFERENCES TO PATHS NOT IN THE BUNDLE:")
            for ref, users in sorted(self.missing_refs.items()):
                log("  ", ref, "used by", sorted(users)[:3])
            raise SystemExit("bundle: references to unbundled store paths")
        # informational: remaining store-path strings in text files
        leftovers = subprocess.run(
            ["grep", "-rIl", "--exclude-dir=python3.14", "/nix/store", str(self.res)],
            capture_output=True, text=True).stdout.split()
        log(f"{len(leftovers)} text files still mention /nix/store (informational):")
        for l in leftovers[:60]:
            log("   ", os.path.relpath(l, self.res))
        total = sum(f.stat().st_size for f in self.app.rglob("*") if f.is_file())
        log(f"bundle size: {total / 1048576:.0f} MiB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gnucash", required=True)
    ap.add_argument("--closure", required=True, help="closureInfo store-paths file")
    ap.add_argument("--app", required=True, help="output GnuCash.app directory")
    ap.add_argument("--version", required=True)
    ap.add_argument("--icns", default="")
    ap.add_argument("--bundle-id", default="org.gnucash.Gnucash.nix")
    a = ap.parse_args()

    b = Bundler(a.gnucash, a.closure, a.app, a.version, a.icns, a.bundle_id)
    b.res.mkdir(parents=True)
    log("merging", len(b.bundled), "store paths")
    b.merge()
    b.unwrap_programs()
    b.fix_shebangs()
    b.write_bundle_files()
    log("rewriting Mach-O load commands")
    b.rewrite_macho()
    b.fix_typelibs()
    b.regenerate_caches()
    b.write_environment()
    b.write_fontconfig()
    b.report()


if __name__ == "__main__":
    main()
