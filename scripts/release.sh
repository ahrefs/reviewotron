#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

version=${1:-}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 X.Y.Z"

for tool in git dune gh strip tar; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

if command -v sha256sum >/dev/null 2>&1; then
  checksum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  checksum_tool=shasum
else
  die "required checksum tool not found: sha256sum or shasum"
fi

[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated"

remote_url=$(git config --get remote.origin.url || true)
remote_repo=${remote_url#git@github.com:}
remote_repo=${remote_repo#https://github.com/}
remote_repo=${remote_repo#ssh://git@github.com/}
remote_repo=${remote_repo%.git}
[[ "$remote_repo" == */* ]] || die "origin is not a GitHub repository"

github_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
[[ "$github_repo" == "$remote_repo" ]] || die "GitHub repository mismatch: origin=$remote_repo gh=$github_repo"

tag="v$version"
git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null && die "tag already exists: $tag"
if gh api "repos/$github_repo/git/ref/tags/$tag" >/dev/null 2>&1; then
  die "GitHub tag already exists: $tag"
fi
if gh release view "$tag" >/dev/null 2>&1; then
  die "GitHub release already exists: $tag"
fi

dune runtest
dune build --profile=release src/reviewotron.exe

release_name="reviewotron-v${version}-linux-x86_64-nspawn"
archive_name="${release_name}.tar.gz"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
stage_dir="$work_dir/$release_name"
mkdir -p "$stage_dir"
install -m 755 _build/default/src/reviewotron.exe "$stage_dir/reviewotron"
strip "$stage_dir/reviewotron"
tar -C "$work_dir" -czf "$work_dir/$archive_name" "$release_name"

if [[ "$checksum_tool" == sha256sum ]]; then
  (cd "$work_dir" && sha256sum "$archive_name" > SHA256SUMS)
else
  (cd "$work_dir" && shasum -a 256 "$archive_name" > SHA256SUMS)
fi

extract_dir="$work_dir/extract"
mkdir -p "$extract_dir"
tar -xzf "$work_dir/$archive_name" -C "$extract_dir"
"$extract_dir/$release_name/reviewotron" --help >/dev/null

release_url=$(gh release create "$tag" "$work_dir/$archive_name" "$work_dir/SHA256SUMS" --draft --generate-notes --title "Reviewotron $tag")
gh release edit "$tag" --draft=false >/dev/null
printf '%s\n' "$release_url"
