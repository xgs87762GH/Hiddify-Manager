#!/usr/bin/env bash
# Publish the admin UI build for the current panel commit.
#
# Servers then install it instead of running npm: build_panel_admin_ui looks the
# commit up in prebuilt-manifest.tsv, downloads the tarball from the `prebuilt`
# branch and verifies its sha256 before unpacking.
#
#   bash scripts/publish_admin_ui.sh [--panel-src DIR] [--no-build] [--no-push]
#
# Run it from a normal branch checkout of the panel (detached HEAD only warns, so
# a submodule still works, but the manifest commit cannot be created there).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/services/panel/src"
BRANCH="prebuilt"
KEEP_ARTIFACTS=6
DO_BUILD=1
DO_PUSH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --panel-src) SRC="$2"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --no-push) DO_PUSH=0; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

SRC="${SRC%/}"
[ -f "$SRC/hiddifypanel/admin_v2/package.json" ] || { echo "not a panel source tree: $SRC" >&2; exit 1; }

REMOTE="$(git -C "$SRC" remote get-url origin)"
SLUG="$(printf '%s' "$REMOTE" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
[ -n "$SLUG" ] || { echo "cannot derive owner/repo from $REMOTE" >&2; exit 1; }

REV="$(git -C "$SRC" rev-parse HEAD)"
SHORT="$(git -C "$SRC" rev-parse --short=12 HEAD)"
STATIC="$SRC/hiddifypanel/static"
UI="$SRC/hiddifypanel/admin_v2"

if [ "$DO_BUILD" = 1 ]; then
    echo "Building the admin UI for $SHORT"
    if [ ! -d "$UI/node_modules" ]; then
        ( cd "$UI" && npm ci --no-audit --no-fund --loglevel=error )
    fi
    ( cd "$UI" && npm run build )
fi
[ -f "$STATIC/admin-v2/index.html" ] || { echo "no build output in $STATIC/admin-v2" >&2; exit 1; }

WORK="$(mktemp -d /var/tmp/hiddify-publish-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ARTIFACT="admin-v2-$SHORT.tar.gz"
tar -czf "$WORK/$ARTIFACT" -C "$STATIC" admin-v2
SUM="$(sha256sum "$WORK/$ARTIFACT" | cut -d' ' -f1)"
SIZE="$(du -h "$WORK/$ARTIFACT" | cut -f1)"
echo "artifact: $ARTIFACT ($SIZE) sha256=$SUM"

# Push the artifact onto the dedicated branch, keeping only the newest few so a
# shallow clone on the server stays small.
REPO="$WORK/repo"
if git clone --depth 1 --branch "$BRANCH" --single-branch --quiet "$REMOTE" "$REPO" 2>/dev/null; then
    :
else
    git init --quiet -b "$BRANCH" "$REPO"
    git -C "$REPO" remote add origin "$REMOTE"
fi
cp "$WORK/$ARTIFACT" "$REPO/$ARTIFACT"
( cd "$REPO" && ls -t prebuilt-manifest.tsv admin-v2-*.tar.gz 2>/dev/null | grep '\.tar\.gz$' | tail -n +$((KEEP_ARTIFACTS + 1)) | xargs -r rm -f )
git -C "$REPO" add -A
if git -C "$REPO" diff --cached --quiet; then
    echo "artifact already published; branch left untouched"
else
    git -C "$REPO" -c user.name="admin-ui bot" -c user.email="bot@localhost" commit --quiet -m "admin-v2 $SHORT"
    if [ "$DO_PUSH" = 1 ]; then
        git -C "$REPO" push --quiet origin "$BRANCH"
        echo "pushed $BRANCH -> $SLUG"
    else
        echo "--no-push: artifact committed locally in $REPO (temporary)"
    fi
fi

# Record the checksum on the manager side, next to the submodule pointer it belongs
# to: committing it in the panel would move the panel HEAD past the artifact.
MANIFEST="$ROOT/scripts/admin-ui-prebuilt.tsv"
[ -f "$MANIFEST" ] || printf '# <panel commit>  <artifact>  <sha256>\n' > "$MANIFEST"
tmpm="$(mktemp)"
awk -v r="$REV" '$1 != r' "$MANIFEST" > "$tmpm"
printf '%s  %s  %s\n' "$REV" "$ARTIFACT" "$SUM" >> "$tmpm"
mv "$tmpm" "$MANIFEST"
echo "updated $MANIFEST"

MGR_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [ "$MGR_BRANCH" = "HEAD" ]; then
    echo "manager is on a detached HEAD; commit the manifest and the submodule pointer yourself"
    exit 0
fi
git -C "$ROOT" add -- scripts/admin-ui-prebuilt.tsv services/panel/src
if git -C "$ROOT" diff --cached --quiet; then
    echo "manifest and submodule pointer already up to date"
    exit 0
fi
git -C "$ROOT" -c user.name="admin-ui bot" -c user.email="bot@localhost" commit --quiet -m "chore: publish admin UI artifact for panel $SHORT"
if [ "$DO_PUSH" = 1 ]; then
    git -C "$ROOT" push --quiet origin "$MGR_BRANCH"
    echo "pushed $MGR_BRANCH to the manager remote"
fi
