#!/bin/bash
# Package the self-contained app into a DMG, optionally signed and notarized.
#
#   nix build ./dev-env#gnucash-app --out-link dev-env/result-gnucash-app
#   dev-env/make-dmg.sh                                  # ad-hoc signed
#   GNC_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" dev-env/make-dmg.sh
#   GNC_SIGN_IDENTITY=... GNC_NOTARY_PROFILE=gnucash-notary dev-env/make-dmg.sh
#
# Nothing secret is stored here: the identity names a certificate in your
# login keychain (`security find-identity -v -p codesigning` lists them),
# and the notary profile is a keychain item created once with
# `xcrun notarytool store-credentials <profile>` (Apple ID + app-specific
# password + team id, kept by the keychain, not by this script).
#
# Without an identity the app keeps its ad-hoc signature: it runs on the
# building machine, and on other Macs after right-click -> Open. A
# "Developer ID Application" identity signs with the hardened runtime and,
# with a notary profile, notarizes and staples the DMG so Gatekeeper
# accepts it silently. An "Apple Development" identity only verifies the
# signing mechanics; Gatekeeper on other Macs still prompts.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src="$here/result-gnucash-app/Applications/GnuCash.app"
[ -d "$src" ] || { echo "build the app first: nix build ./dev-env#gnucash-app --out-link dev-env/result-gnucash-app" >&2; exit 1; }

identity=${1:-${GNC_SIGN_IDENTITY:-}}
notary=${GNC_NOTARY_PROFILE:-}

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$src/Contents/Info.plist")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A writable copy (store paths are read-only) with normal permissions.
ditto "$src" "$work/GnuCash.app"
chmod -R u+w "$work/GnuCash.app"

if [ -n "$identity" ]; then
    echo "signing with: $identity"
    # sign inside-out: every Mach-O first, then the bundle itself
    find "$work/GnuCash.app/Contents/Resources" -type f \
        \( -name '*.dylib' -o -name '*.so' -o -name '*.bundle' -o -perm -u+x \) -print0 |
      while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            codesign --force --options runtime --timestamp --sign "$identity" "$f"
        fi
      done
    codesign --force --options runtime --timestamp \
        --entitlements "$here/gnucash.entitlements.plist" \
        --sign "$identity" "$work/GnuCash.app"
    codesign --verify --deep --strict --verbose=2 "$work/GnuCash.app"
fi

ln -s /Applications "$work/Applications"
out="$here/GnuCash-$version.dmg"
rm -f "$out"
hdiutil create -volname "GnuCash $version" -srcfolder "$work" -ov -format UDZO "$out"

if [ -n "$identity" ]; then
    codesign --force --timestamp --sign "$identity" "$out"
fi
if [ -n "$notary" ]; then
    echo "notarizing with keychain profile: $notary"
    xcrun notarytool submit "$out" --keychain-profile "$notary" --wait
    xcrun stapler staple "$out"
    spctl --assess --type open --context context:primary-signature -v "$out" || true
fi
echo "created $out"
