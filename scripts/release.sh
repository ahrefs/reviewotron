#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The version is declared once, in dune-project, and baked into the binary by
# the release-profile build. Read it here so the git tag and GitHub release
# stay in lockstep with the compiled-in version.
version=$(sed -n 's/^(version[[:space:]]*\([0-9][0-9.]*\))[[:space:]]*$/\1/p' "$script_dir/../dune-project")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no (version X.Y.Z) in dune-project: '$version'"

for tool in git dune gh strip tar sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated"

# GitHub resolves the release tag against the remote branch, not the local HEAD,
# so releasing with unpushed commits tags a different tree than the one being
# built. Compare against the remote itself rather than the local origin/ ref,
# which may be stale.
branch=$(git rev-parse --abbrev-ref HEAD)
remote_head=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
[[ -n "$remote_head" ]] || die "branch $branch does not exist on origin — push it first"
[[ "$remote_head" == "$(git rev-parse HEAD)" ]] ||
  die "HEAD differs from origin/$branch — push or pull before releasing"

# Fail before the build (minutes) rather than at upload, when the tag is taken.
tag="v$version"
git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null && die "tag already exists: $tag"
gh release view "$tag" >/dev/null 2>&1 && die "GitHub release already exists: $tag"

dune runtest
dune build --profile=release src/reviewotron.exe

# The release ships the prebuilt binary in a gzipped tarball, alongside a
# SHA256SUMS file. The archive name carries the version; the extracted binary is
# plain `reviewotron`.
release_name="reviewotron-v${version}-linux-x86_64"
archive_name="${release_name}.tar.gz"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
stage_dir="$work_dir/$release_name"
mkdir -p "$stage_dir"
install -m 755 _build/default/src/reviewotron.exe "$stage_dir/reviewotron"
strip "$stage_dir/reviewotron"
tar -C "$work_dir" -czf "$work_dir/$archive_name" "$release_name"

(cd "$work_dir" && sha256sum "$archive_name" > SHA256SUMS)

# Verify what is actually being published: extract the archive and check the
# binary runs and reports the version declared in dune-project. Guards against
# publishing a stale build.
extract_dir="$work_dir/extract"
mkdir -p "$extract_dir"
tar -xzf "$work_dir/$archive_name" -C "$extract_dir"
actual_version=$("$extract_dir/$release_name/reviewotron" --version)
[[ "$actual_version" == "$version" ]] || die "built binary reports $actual_version, expected $version"

# Uploaded as a draft first so the assets are never half-uploaded under a live
# tag, then published once they are all in place. `gh release create` prints the
# draft's placeholder URL (releases/tag/untagged-...), so report the tag URL the
# release ends up at instead.
gh release create "$tag" "$work_dir/$archive_name" "$work_dir/SHA256SUMS" --draft --notes "" --title "Reviewotron $tag" >/dev/null
gh release edit "$tag" --draft=false >/dev/null
printf 'https://github.com/%s/releases/tag/%s\n' "$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" "$tag"
