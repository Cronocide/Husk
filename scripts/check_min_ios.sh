#!/bin/bash
# Husk: every Mach-O in a built .app must deploy no higher than the app itself.
#
# Usage: ./scripts/check_min_ios.sh path/to/Husk.app
#
# This exists because a deployment-target mismatch is the one kind of iOS 16
# breakage that survives the whole pipeline. It compiles, it packages, it
# installs, and then dyld refuses the library at launch with a message naming a
# path and no version at all -- indistinguishable from a missing library, which
# is the failure the bundle validation above it was written for.
#
# The risk is real rather than theoretical: Husk's app target is built by
# xcodebuild from project.yml, but libANGLE-shared.dylib, MoltenVK and
# libhusk_rppairing.a each come from their own script with their own
# IPHONEOS_DEPLOYMENT_TARGET, and QEMU comes from build_ios.sh with a third.
# Nothing else notices when one of them moves.
set -uo pipefail

APP="${1:?usage: check_min_ios.sh path/to/Husk.app}"
PLIST="$APP/Info.plist"
[ -f "$PLIST" ] || { echo "no Info.plist at $PLIST" >&2; exit 1; }

TARGET="$(/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$PLIST" 2>/dev/null || true)"
[ -n "$TARGET" ] || { echo "MinimumOSVersion is not set; cannot check" >&2; exit 1; }

# sort -V orders version strings; "the lower of the two is the target" means the
# binary asks for no more than the app promises.
higher_than_target() {
    [ "$(printf '%s\n%s\n' "$TARGET" "$1" | sort -V | head -1)" != "$1" ] \
        && [ "$1" != "$TARGET" ]
}

rc=0
echo "==> deployment targets (app promises iOS $TARGET)"

check() {
    local f="$1" minos
    minos="$(vtool -show-build "$f" 2>/dev/null | awk '/^ *minos/ {print $2; exit}')"
    if [ -z "$minos" ]; then
        # Not every Mach-O carries LC_BUILD_VERSION -- an old LC_VERSION_MIN_IPHONEOS
        # is reported as "version" instead. Neither missing is fatal by itself.
        minos="$(vtool -show-build "$f" 2>/dev/null | awk '/^ *version/ {print $2; exit}')"
    fi
    if [ -z "$minos" ]; then
        printf "  ?        %-40s no load command\n" "${f#"$APP"/}"
        return
    fi
    if higher_than_target "$minos"; then
        printf "  TOO HIGH %-40s iOS %s   <-- dyld will refuse this on iOS %s\n" \
            "${f#"$APP"/}" "$minos" "$TARGET" >&2
        rc=1
    else
        printf "  ok       %-40s iOS %s\n" "${f#"$APP"/}" "$minos"
    fi
}

# The app binary, every loose dylib, every embedded framework's binary, and
# every app extension's binary.
EXE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)"
[ -n "$EXE" ] && [ -f "$APP/$EXE" ] && check "$APP/$EXE"

while IFS= read -r f; do check "$f"; done < <(find "$APP" -name "*.dylib" -type f)

for fw in "$APP"/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    name="$(basename "$fw" .framework)"
    [ -f "$fw/$name" ] && check "$fw/$name"
done

for ex in "$APP"/PlugIns/*.appex; do
    [ -d "$ex" ] || continue
    name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$ex/Info.plist" 2>/dev/null || true)"
    [ -n "$name" ] && [ -f "$ex/$name" ] && check "$ex/$name"
done

[ $rc -eq 0 ] || echo "==> a binary deploys higher than the app; it will not load on iOS $TARGET" >&2
exit $rc
