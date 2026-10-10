#!/usr/bin/env bash
# Description: Build stanza's release asset for a tag (stanza-<version>.tar.gz
#              and its .sha256) and publish both on the tag's GitHub release.
#              install.sh downloads the asset and checks it against the
#              checksum. Safe to re-run: the release is created only when it
#              is missing, only missing assets are uploaded, and an asset that
#              is already published is checked, never replaced.
set -e

show_help() {
    cat <<EOF
Usage: scripts/release-asset.sh [OPTIONS] <TAG>

Build stanza-<version>.tar.gz from the tagged tree (git archive) and its
SHA-256, then publish them on the GitHub release for TAG, creating the
release if needed. Run from the repository; the tag must exist locally.

Arguments:
  TAG             A stable release tag, e.g. v1.2.0

Options:
  --out DIR       Only build the two files into DIR; no GitHub calls
  -h, --help      Show this help

Examples:
  scripts/release-asset.sh v1.2.0             # build and publish
  scripts/release-asset.sh --out dist v1.2.0  # build only
EOF
}

error() {
    echo "Error: $*" >&2
}

OUT_DIR=""
TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)
            if [[ $# -lt 2 || -z "$2" ]]; then
                error "--out requires a directory"
                exit 1
            fi
            OUT_DIR="$2"
            shift 2
            ;;
        --out=*)
            OUT_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -n "$TAG" ]]; then
                error "Unexpected argument: $1"
                exit 1
            fi
            TAG="$1"
            shift
            ;;
    esac
done

if [[ -z "$TAG" ]]; then
    show_help >&2
    exit 1
fi
# stanza tags stable releases only, and install.sh installs only those
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Not a stable release tag: $TAG (expected vX.Y.Z)"
    exit 1
fi
if ! git rev-parse -q --verify "refs/tags/$TAG^{commit}" > /dev/null; then
    error "Tag $TAG not found in this repository (git fetch --tags?)"
    exit 1
fi

VERSION="${TAG#v}"
NAME="stanza-$VERSION.tar.gz"

sha256_of() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Build the tarball (one top-level stanza-<version>/ directory) and its
# checksum file, in sha256sum's format, into $1
build() {
    local dir="$1"
    mkdir -p "$dir"
    git archive --format=tar.gz --prefix="stanza-$VERSION/" -o "$dir/$NAME" "$TAG"
    write_checksum "$dir"
}

write_checksum() {
    local dir="$1"
    printf '%s  %s\n' "$(sha256_of "$dir/$NAME")" "$NAME" > "$dir/$NAME.sha256"
}

# This version's section of CHANGELOG.md at the tag, for the release notes
release_notes() {
    git show "$TAG:CHANGELOG.md" 2>/dev/null | awk -v v="$VERSION" '
        $0 ~ "^## \\[" v "\\]" { on = 1; next }
        on && /^## \[/ { exit }
        on && /^\[[^]]*\]: / { exit }
        on { print }
    '
}

if [[ -n "$OUT_DIR" ]]; then
    build "$OUT_DIR"
    echo "$OUT_DIR/$NAME"
    echo "$OUT_DIR/$NAME.sha256"
    exit 0
fi

if ! command -v gh > /dev/null; then
    error "gh (GitHub CLI) is required to publish; use --out DIR to build only"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! gh release view "$TAG" > /dev/null 2>&1; then
    build "$WORK"
    notes="$(release_notes)"
    [[ -n "$notes" ]] || notes="stanza $TAG"
    gh release create "$TAG" --verify-tag --title "$TAG" --notes "$notes" \
        "$WORK/$NAME" "$WORK/$NAME.sha256"
    echo "Created release $TAG with $NAME and $NAME.sha256"
    exit 0
fi

assets="$(gh release view "$TAG" --json assets --jq '.assets[].name')"
has_asset() {
    grep -qxF "$1" <<< "$assets"
}

# A published tarball is never rebuilt: git archive's gzip output can change
# between git versions, so the checksum is always taken from the bytes that
# installers download.
if has_asset "$NAME"; then
    gh release download "$TAG" --pattern "$NAME" --dir "$WORK"
    write_checksum "$WORK"
else
    build "$WORK"
    gh release upload "$TAG" "$WORK/$NAME"
    echo "Uploaded $NAME to $TAG"
fi

if has_asset "$NAME.sha256"; then
    mkdir "$WORK/published"
    gh release download "$TAG" --pattern "$NAME.sha256" --dir "$WORK/published"
    if ! cmp -s "$WORK/$NAME.sha256" "$WORK/published/$NAME.sha256"; then
        error "The published $NAME.sha256 does not match $NAME on release $TAG"
        echo "  published: $(head -1 "$WORK/published/$NAME.sha256")" >&2
        echo "  computed:  $(head -1 "$WORK/$NAME.sha256")" >&2
        exit 1
    fi
    echo "Release $TAG already has $NAME and a matching checksum"
else
    gh release upload "$TAG" "$WORK/$NAME.sha256"
    echo "Uploaded $NAME.sha256 to $TAG"
fi
