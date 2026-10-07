#!/usr/bin/env bash
# Points the Homebrew cask in snowztech/homebrew-tap at a release, like `bump-cask.sh 0.1.1 build/Farol.dmg`.
# TAP_DEPLOY_KEY is a deploy key with write access to the tap. Without it, your own git access is used.
set -euo pipefail

version="$1"
sha=$(shasum -a 256 "$2" | cut -d' ' -f1)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -n "${TAP_DEPLOY_KEY:-}" ]; then
  (umask 077 && echo "$TAP_DEPLOY_KEY" > "$work/key")
  export GIT_SSH_COMMAND="ssh -i $work/key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi

tap="$work/tap"
git clone -q --depth 1 git@github.com:snowztech/homebrew-tap.git "$tap"
sed -i '' \
  -e "s/^  version \".*\"/  version \"$version\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
  "$tap/Casks/farol.rb"

if git -C "$tap" diff --quiet; then
  echo "cask is already at $version"
  exit 0
fi
git -C "$tap" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -qam "chore: bump farol to $version"
git -C "$tap" push -q
echo "cask bumped to $version"
