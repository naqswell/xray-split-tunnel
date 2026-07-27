#!/usr/bin/env bash
# Build a deterministic, checksummed archive from an exact v<VERSION> tag.
set -euo pipefail
umask 077

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$RELEASE_ROOT/dist}"
VERSION="$(sed -n '1p' "$RELEASE_ROOT/VERSION")"
EXPECTED_TAG="v$VERSION"
COMMIT="$(git -C "$RELEASE_ROOT" rev-parse --verify HEAD)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  { echo "invalid VERSION: $VERSION" >&2; exit 1; }
if ! WORKTREE_STATUS="$(git -C "$RELEASE_ROOT" status --porcelain)"; then
  echo "git status failed; release provenance is not proven" >&2
  exit 1
fi
[[ -z "$WORKTREE_STATUS" ]] ||
  { echo "release requires a clean worktree" >&2; exit 1; }
ACTUAL_TAG="$(git -C "$RELEASE_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
[[ "$ACTUAL_TAG" == "$EXPECTED_TAG" ]] ||
  { echo "HEAD must have exact tag $EXPECTED_TAG" >&2; exit 1; }

make -C "$RELEASE_ROOT" test

if [[ -L "$OUTPUT_DIR" || ( -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ) ]]; then
  echo "output path must be a real directory, not a symlink/file" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
[[ ! -L "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]] ||
  { echo "output directory safety check failed" >&2; exit 1; }
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ARCHIVE_BASENAME="xray-split-tunnel-$VERSION.tar.gz"
ARCHIVE="$OUTPUT_DIR/$ARCHIVE_BASENAME"
MANIFEST="$OUTPUT_DIR/$ARCHIVE_BASENAME.manifest"
if [[ -e "$ARCHIVE" || -L "$ARCHIVE" || -e "$MANIFEST" || -L "$MANIFEST" ]]; then
  echo "release artifacts already exist; refusing to overwrite" >&2
  exit 1
fi
TEMP_DIR="$(mktemp -d "$OUTPUT_DIR/.xst-release.XXXXXX")"
RELEASE_ARTIFACTS_PUBLISHED=0
RELEASE_COMPLETE=0
cleanup_release() {
  trap '' HUP INT TERM
  if [[ "${RELEASE_ARTIFACTS_PUBLISHED:-0}" == 1 &&
        "${RELEASE_COMPLETE:-0}" != 1 ]]; then
    rm -f "$ARCHIVE" "$MANIFEST"
  fi
  if [[ -n "${TEMP_DIR:-}" && "$TEMP_DIR" == "$OUTPUT_DIR"/.xst-release.* ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup_release EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

git -C "$RELEASE_ROOT" archive \
  --format=tar \
  --prefix="xray-split-tunnel-$VERSION/" \
  HEAD > "$TEMP_DIR/release.tar"
gzip -n -9 < "$TEMP_DIR/release.tar" > "$TEMP_DIR/$ARCHIVE_BASENAME"

ARCHIVED_REVISION="$(
  gzip -dc "$TEMP_DIR/$ARCHIVE_BASENAME" |
    tar -xOf - \
    "xray-split-tunnel-$VERSION/REVISION"
)"
ARCHIVED_COMMIT="$ARCHIVED_REVISION"
[[ "$ARCHIVED_COMMIT" == "$COMMIT" ]] ||
  { echo "REVISION was not substituted with archive commit" >&2; exit 1; }
[[ "$ARCHIVED_REVISION" != *'$Format:'* ]] ||
  { echo "REVISION still contains an export-subst placeholder" >&2; exit 1; }

CHECKSUM="$(shasum -a 256 "$TEMP_DIR/$ARCHIVE_BASENAME" | awk '{print $1}')"
{
  printf 'project=xray-split-tunnel\n'
  printf 'version=%s\n' "$VERSION"
  printf 'tag=%s\n' "$EXPECTED_TAG"
  printf 'commit=%s\n' "$COMMIT"
  printf 'archive=%s\n' "$ARCHIVE_BASENAME"
  printf 'sha256=%s\n' "$CHECKSUM"
} > "$TEMP_DIR/manifest"

MANIFEST_COMMIT="$(sed -n 's/^commit=//p' "$TEMP_DIR/manifest")"
[[ "$MANIFEST_COMMIT" == "$ARCHIVED_COMMIT" ]] ||
  { echo "manifest commit does not match archived revision" >&2; exit 1; }

chmod 644 "$TEMP_DIR/$ARCHIVE_BASENAME" "$TEMP_DIR/manifest"
publish_release_artifacts() {
  trap '' HUP INT TERM
  if ! ln "$TEMP_DIR/$ARCHIVE_BASENAME" "$ARCHIVE"; then
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    return 1
  fi
  if ! ln "$TEMP_DIR/manifest" "$MANIFEST"; then
    rm -f "$ARCHIVE"
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    return 1
  fi
  RELEASE_ARTIFACTS_PUBLISHED=1
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
publish_release_artifacts ||
  { echo "could not publish release artifacts without overwrite" >&2; exit 1; }
rm -f "$TEMP_DIR/$ARCHIVE_BASENAME" "$TEMP_DIR/manifest"
if ! FINAL_CHECKSUM="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"; then
  rm -f "$ARCHIVE" "$MANIFEST"
  echo "could not verify published archive" >&2
  exit 1
fi
if [[ "$FINAL_CHECKSUM" != "$CHECKSUM" ]]; then
  rm -f "$ARCHIVE" "$MANIFEST"
  echo "final archive checksum changed during publication" >&2
  exit 1
fi
RELEASE_COMPLETE=1

printf 'archive:  %s\nmanifest: %s\nsha256:   %s\n' "$ARCHIVE" "$MANIFEST" "$CHECKSUM"
