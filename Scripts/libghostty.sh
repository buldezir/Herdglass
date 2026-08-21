#!/bin/bash
# Build libghostty from the pinned ghostty checkout in Vendor/ghostty into
# Vendor/GhosttyKit.xcframework — the binary target Package.swift links.
#
# The artifact is not in git (it is ~24 MB and reproducible from the pin), so a
# fresh clone runs this once. Zig is pinned by ghostty itself and is downloaded
# here when the one on PATH is a different version, which Homebrew's usually is.
set -euo pipefail
cd "$(dirname "$0")/.."

SUBMODULE="Vendor/ghostty"
ARTIFACT="Vendor/GhosttyKit.xcframework"
VERSION_FILE="Vendor/libghostty.version"
ZIG_DIR="Vendor/zig"

CHECK=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "usage: Scripts/libghostty.sh [--check] [--force]"
      echo "  --check  report whether the built artifact matches the pinned ghostty commit"
      echo "  --force  rebuild even when it already matches"
      exit 0 ;;
    *) echo "libghostty.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

if [ ! -f "$SUBMODULE/build.zig" ]; then
  if [ "$CHECK" = 1 ]; then
    echo "libghostty: $SUBMODULE is empty. Run: git submodule update --init $SUBMODULE" >&2
    exit 1
  fi
  git submodule update --init "$SUBMODULE"
fi

PINNED="$(git -C "$SUBMODULE" rev-parse HEAD)"
BUILT="$(sed -n 's/^ghostty_commit=//p' "$VERSION_FILE" 2>/dev/null || true)"

# Both halves matter: the artifact can be missing on a fresh clone, and it can
# be stale after the pin moves.
if [ -d "$ARTIFACT" ] && [ "$BUILT" = "$PINNED" ]; then
  if [ "$CHECK" = 1 ]; then
    echo "libghostty: $ARTIFACT is built from ${PINNED:0:9}"
    exit 0
  fi
  if [ "$FORCE" = 0 ]; then
    echo "libghostty: $ARTIFACT is already built from ${PINNED:0:9} (--force to rebuild)"
    exit 0
  fi
elif [ "$CHECK" = 1 ]; then
  if [ ! -d "$ARTIFACT" ]; then
    echo "libghostty: $ARTIFACT is missing. Run: Scripts/libghostty.sh" >&2
  else
    if [ -z "$BUILT" ]; then
      echo "libghostty: $ARTIFACT has no $VERSION_FILE, so what it holds is unknown." >&2
    else
      echo "libghostty: $ARTIFACT is built from ${BUILT:0:9}, but the pin is ${PINNED:0:9}." >&2
    fi
    echo "            Run: Scripts/libghostty.sh" >&2
  fi
  exit 1
fi

# ghostty pins its toolchain hard; a newer zig fails the build rather than
# tolerating it, so match the version exactly.
ZIG_VERSION="$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$SUBMODULE/build.zig.zon" | head -n 1)"
if [ -z "$ZIG_VERSION" ]; then
  echo "libghostty: no minimum_zig_version in $SUBMODULE/build.zig.zon" >&2
  exit 1
fi

case "$(uname -s):$(uname -m)" in
  Darwin:arm64) ZIG_TARGET="aarch64-macos" ;;
  Darwin:x86_64) ZIG_TARGET="x86_64-macos" ;;
  *) echo "libghostty: this builds on macOS only ($(uname -s):$(uname -m))" >&2; exit 1 ;;
esac

ZIG=""
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$ZIG_VERSION" ]; then
  ZIG="$(command -v zig)"
fi
# Zig's tarballs have been named both zig-<os>-<arch>-<version> and
# zig-<arch>-<os>-<version>, so look for any unpacked toolchain that reports the
# version we want rather than guessing the directory name.
if [ -z "$ZIG" ]; then
  for candidate in "$ZIG_DIR"/*/zig; do
    if [ -x "$candidate" ] && [ "$("$candidate" version)" = "$ZIG_VERSION" ]; then
      ZIG="$PWD/$candidate"
      break
    fi
  done
fi

if [ -z "$ZIG" ]; then
  echo "libghostty: downloading zig $ZIG_VERSION ($ZIG_TARGET)"
  INDEX="$(mktemp -t herdglass-zig-index)"
  trap 'rm -f "$INDEX"' EXIT
  curl -fsSL https://ziglang.org/download/index.json -o "$INDEX"
  read -r TARBALL SHASUM <<EOF
$(python3 - "$INDEX" "$ZIG_VERSION" "$ZIG_TARGET" <<'PY'
import json, sys
index_path, version, target = sys.argv[1:]
with open(index_path, encoding="utf-8") as handle:
    index = json.load(handle)
try:
    artifact = index[version][target]
    print(artifact["tarball"], artifact["shasum"])
except KeyError:
    sys.exit(f"zig {version} publishes no {target} tarball")
PY
)
EOF
  DOWNLOAD="$(mktemp -d -t herdglass-zig)"
  curl -fsSL "$TARBALL" -o "$DOWNLOAD/zig.tar.xz"
  printf '%s  %s\n' "$SHASUM" "$DOWNLOAD/zig.tar.xz" | shasum -a 256 -c - >/dev/null
  mkdir -p "$ZIG_DIR"
  rm -rf "$ZIG_DIR/$(basename "$TARBALL" .tar.xz)"
  tar -xJf "$DOWNLOAD/zig.tar.xz" -C "$ZIG_DIR"
  rm -rf "$DOWNLOAD"
  ZIG="$PWD/$ZIG_DIR/$(basename "$TARBALL" .tar.xz)/zig"
  [ "$("$ZIG" version)" = "$ZIG_VERSION" ] || {
    echo "libghostty: downloaded zig is $("$ZIG" version), expected $ZIG_VERSION" >&2
    exit 1
  }
fi

# Build in a throwaway clone: `zig build` writes macos/ and .zig-cache into the
# tree it runs in, and the submodule has to stay clean for `--check` to mean
# anything.
WORK="$(mktemp -d -t herdglass-libghostty)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "libghostty: building ghostty ${PINNED:0:9} with zig $ZIG_VERSION (this takes a while)"
git clone --quiet --local "$SUBMODULE" "$WORK/ghostty"
git -C "$WORK/ghostty" checkout --quiet --detach "$PINNED"
(
  cd "$WORK/ghostty"
  "$ZIG" build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target=native
)

BUILT_ARTIFACT="$WORK/ghostty/macos/GhosttyKit.xcframework"
[ -d "$BUILT_ARTIFACT" ] || {
  echo "libghostty: zig build produced no $BUILT_ARTIFACT" >&2
  exit 1
}

rm -rf "$ARTIFACT"
mkdir -p "$(dirname "$ARTIFACT")"
cp -R "$BUILT_ARTIFACT" "$ARTIFACT"
# Debug info stays in the .dSYM the xcframework already carries; keeping it in
# the archive as well doubles what every link has to read.
find "$ARTIFACT" -name '*.a' -type f -exec strip -S {} +

cat > "$VERSION_FILE" <<EOF
# Written by Scripts/libghostty.sh. Vendor/GhosttyKit.xcframework was built
# from this ghostty commit; Scripts/libghostty.sh --check compares it with the
# Vendor/ghostty pin.
ghostty_commit=$PINNED
ghostty_ref=$(git -C "$SUBMODULE" describe --tags --always --match 'v*' "$PINNED")
zig_version=$ZIG_VERSION
built_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "libghostty: built $ARTIFACT ($(du -sh "$ARTIFACT" | cut -f1)) from ${PINNED:0:9}"
