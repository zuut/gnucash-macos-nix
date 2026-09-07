# GnuCash on macOS via Nix

Reproducible, isolated environment for building and running GnuCash
(GUI, WebKit reports, AqBanking, Finance::Quote, Python bindings) on
Apple silicon. Everything is pinned in `flake.nix` / `flake.lock`.

## The app (standard way)

```sh
nix build ./dev-env#gnucash
open dev-env/result-gnucash/Applications/GnuCash.app
```

`packages.gnucash` is nixpkgs' own gnucash derivation, built from the
checkout in `../gnucash` (the `gnucash-src` flake input, pinned to a
commit; run `nix flake update gnucash-src` in `dev-env/` after committing
changes you want in the app). It gets the darwin WebKit port, AqBanking
and the enlarged-GC guile defined here, is installed normally
(`ninja install` into the store, no uninstalled-mode hacks), and
`desktopToDarwinBundle` generates the `.app` from GnuCash's `.desktop`
file and icons. Runtime environment (fonts, icon themes, Perl/Python
paths, GSettings) is applied by nixpkgs' `wrapGAppsHook3`.

The package also builds the help documentation (`gnucashDocs`, HTML from
DocBook) and links it where macOS GnuCash's Help menu looks, and it uses
`librsvgFixed`: nixpkgs' librsvg ships its darwin gdk-pixbuf loader without
the rpath it needs, so no SVG (including GTK's own symbolic icons) would
load; the override rewrites the install name and regenerates the loader
cache.

One GnuCash quirk handled in the package: with Mac integration enabled,
the generated `etc/gnucash/environment` appends bundle-layout paths
(`GDK_PIXBUF_MODULE_FILE`, `GNC_DBD_DIR`, `GTK_EXE_PREFIX`, …) that GnuCash
force-applies at startup; on Nix those point nowhere, so the package strips
them at install and the wrapper supplies the right values.

To keep it in `~/Applications`, copy the bundle or symlink it:

```sh
ln -sfn "$PWD/dev-env/result-gnucash/Applications/GnuCash.app" ~/Applications/GnuCash.app
```

## The redistributable app (no Nix needed to run it)

```sh
nix build ./dev-env#gnucash-app --out-link dev-env/result-gnucash-app
dev-env/make-dmg.sh                       # -> dev-env/GnuCash-<version>.dmg
dev-env/make-dmg.sh "Developer ID Application: Name (TEAMID)"   # signed
```

`packages.gnucash-app` is a self-contained `GnuCash.app` built by
`bundle-app.py` from the package's runtime closure, the same design as the
official gtk-mac-bundler build: every needed store path is merged into one
prefix under `Contents/Resources/{bin,lib,libexec,share,etc}`, all Mach-O
load commands are rewritten to `@rpath` + one `@loader_path` rpath per
binary, the module caches (gdk-pixbuf, GTK input methods, GIO, GSettings,
MIME, icons) are regenerated with bundle-relative entries, and GnuCash's own
`etc/gnucash/environment` file points every library at the bundle relative
to `GNC_HOME` (= `Contents/Resources`, which GnuCash derives from the
bundle at startup). The result runs from anywhere — copied to another Mac,
from a mounted DMG — without touching `/nix`. Python (bindings + plugin),
Guile, WebKit helpers and AqBanking/libchipcard are all inside. Toolchain-only
store paths, `-dev` outputs, headers, static libraries and non-English
manuals are left out.

Perl and Finance::Quote are deliberately *not* bundled, exactly like the
official app: quote sources change all the time, so any pinned copy goes
stale. Quotes run on the system `/usr/bin/perl` and Finance::Quote is
installed/updated independently (`gnc-fq-update`, or `cpan Finance::Quote`;
GnuCash also needs `JSON::Parse`). This applies to the Nix package as
well: it links no Perl modules and its quote scripts use `/usr/bin/perl`.

Without a Developer ID the app is ad-hoc signed: recipients open it once
with right-click → Open. `make-dmg.sh <identity>` signs with the hardened
runtime (`gnucash.entitlements.plist`); notarize the DMG afterwards.

## Hacking on GnuCash

```sh
nix develop ./dev-env#gui      # full toolchain + deps, nix-built webkit
cmake -G Ninja -S gnucash -B build-gui -DWITH_GNUCASH=ON -DWITH_AQBANKING=ON -DWITH_PYTHON=ON
ninja -C build-gui && ninja -C build-gui check
```

Shells: `default` (headless, no webkit), `gui` (nix-built webkit),
`gui-manual` (webkit from `../webkit-work`, for iterating on the webkit
port), `webkit` (webkit's own build deps).

Running an *uninstalled* build from `build-gui` needs the install-only
share files staged (`stage-share.sh`) and `GNC_UNINSTALLED=YES`; prefer
`nix build .#gnucash` for actually using the app.

## WebKitGTK on macOS

nixpkgs marks webkitgtk broken on darwin. `packages.webkitgtk` builds it
anyway: full git source (the tarball strips the darwin files), ANGLE on
Metal (WebGL), ANGLE-provided EGL instead of libepoxy, cairo renderer,
unix-domain-socket IPC with darwin fixes (SOCK_DGRAM, buffer sizes,
timer-based write retry), shared-memory frame transport, helper-process
watchdog and task-switcher hiding. See the comments in `flake.nix`.
Known gap: the GL compositor renders black, so the software path is used
(`WEBKIT_DISABLE_COMPOSITING_MODE=1`); WebGL is compiled in but not
displayable until that is fixed.

## Files

- `flake.nix`, `flake.lock` — the environment.
- `bundle-app.py` — builds the self-contained `GnuCash.app` (`packages.gnucash-app`).
- `make-dmg.sh`, `gnucash.entitlements.plist` — DMG packaging and optional signing.
- `PlatformGTK-darwin.cmake` — ANGLE platform file for the GTK port on macOS.
- `webkit-probe.c` — tiny WebKitGTK render/load probe used for diagnosis.
- `manual-ninja.sh`, `stage-share.sh` — helpers for the manual workspaces.
