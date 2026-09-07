# Licensing

The Nix expressions, `bundle-app.py`, `make-dmg.sh`, the helper scripts and
the documentation in this repository are released under the MIT License
(see `LICENSE`).

`PlatformGTK-darwin.cmake` is modelled on ANGLE's `PlatformGTK.cmake` from
the WebKit tree (BSD-3-Clause, copyright the ANGLE Project Authors).

What this repository builds is not covered by the MIT license: GnuCash is
GPL-2.0-or-later, WebKitGTK is LGPL-2.1/BSD, and the app bundle produced by
`packages.gnucash-app` contains them and their dependencies. Distributing
that bundle (the DMG) therefore carries the GPL's source obligations: the
corresponding source is the pinned GnuCash checkout plus the patches applied
in `flake.nix`, all of which `flake.lock` identifies exactly, so publishing
the tag of this repository a DMG was built from satisfies them.
