#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WINE_ROOT="$ROOT/wine"
UPSTREAM="$WINE_ROOT/upstream"
JUICE_DIR="$UPSTREAM/Juice"

JUICE_REPO="https://github.com/ExoCore-Kernel/Juice.git"
JUICE_COMMIT="c0de19d93064eac25f87524849e12bb2d49e9a4f"

echo "== WinArc Wine Base =="
echo "Product: WinArc"
echo "Component: modified Wine base"
echo "Upstream: Juice/Grape"
echo "Pinned commit: $JUICE_COMMIT"

mkdir -p "$UPSTREAM"

if test ! -d "$JUICE_DIR/.git"; then
    rm -rf "$JUICE_DIR"
    git clone --filter=blob:none "$JUICE_REPO" "$JUICE_DIR"
fi

git -C "$JUICE_DIR" fetch --quiet origin "$JUICE_COMMIT"
git -C "$JUICE_DIR" checkout --detach "$JUICE_COMMIT"

actual="$(git -C "$JUICE_DIR" rev-parse HEAD)"
test "$actual" = "$JUICE_COMMIT" || {
    echo "Pinned Juice commit mismatch: $actual" >&2
    exit 2
}

# Clean Base policy:
# Keep the proven Wine/iOS and translation work intact.
# Do not execute Juice's TrollStore/TIPA/CoreTrust/device build entry points.
#
# We deliberately do not delete source files yet. Deletion before the
# replacement process model exists would destroy a known-good reference path.
# Instead this gate marks jailbreak-only entry points as forbidden for WinArc.

for required in \
    wine \
    app \
    scripts \
    config
do
    test -e "$JUICE_DIR/$required" || {
        echo "Missing expected Juice path: $required" >&2
        exit 3
    }
done

for forbidden in \
    scripts/package-tipa.sh \
    scripts/install-tipa-device.sh \
    scripts/coretrust-sign-device.sh \
    scripts/bootstrap-trust-carrier-device.sh
do
    if test -e "$JUICE_DIR/$forbidden"; then
        echo "WINARC_WINE_DISABLED_ENTRY=$forbidden"
    fi
done

cat > "$WINE_ROOT/BASELINE" <<EOF
WINARC_COMPONENT=wine
UPSTREAM=ExoCore-Kernel/Juice
UPSTREAM_COMMIT=$JUICE_COMMIT
WINE_LAYER_NAME=Wine
PRODUCT_NAME=WinArc
TROLLSTORE_MAINLINE=NO
TIPA_MAINLINE=NO
VAR_JB_MAINLINE=NO
CORETRUST_MAINLINE=NO
WINE_CORE_MUTATED=NO
TRACE_PARENT_MUTATED=NO
NEXT_STAGE=replace-trace-parent-and-child-process-model
EOF

echo "WINARC_WINE_BASE=PASS"
echo "SOURCE=$JUICE_DIR"
echo "STATE=$WINE_ROOT/BASELINE"
echo "NEXT=replace trace-parent / child Wine process model"
