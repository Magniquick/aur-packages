#!/usr/bin/env bash
# Bump the PKGBUILD to the latest upstream release.
#
# A release is taken only when all of these hold:
#   - it was published by upstream's release workflow (github-actions[bot]),
#   - it is at least MIN_AGE_HOURS old (default 24), so a bad or compromised
#     release has time to be pulled before it reaches the AUR,
#   - every upstream check run on the tagged commit has completed without
#     failing, and the test suite and Arch container jobs are among them.
#
# Checksums come from GitHub's asset digests; makepkg verifies the real
# downloads against them in the build step.
#
# Exit 0 with no changes when there is nothing to do or the release is still
# waiting. Exit 1 when a release needs a human look. On a bump, the AUR commit
# message is written to $COMMIT_MSG_FILE when that is set.
set -euo pipefail
cd "$(dirname "$0")"

upstream=JohnRTitor/xdg-desktop-portal-gtk4
min_age_hours=${MIN_AGE_HOURS:-24}
required_checks=('test (stable)' 'test (archlinux:latest)')

api() {
	local auth=()
	[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
	curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "${auth[@]}" \
		"https://api.github.com/$1"
}

release=$(api "repos/$upstream/releases/latest")
tag=$(jq -r .tag_name <<<"$release")
ver=${tag#v}
cur=$(sed -n 's/^pkgver=//p' PKGBUILD)

if (($(vercmp "$ver" "$cur") <= 0)); then
	echo "Up to date at $cur (latest upstream release is $ver)."
	exit 0
fi
echo "Upstream release $ver is newer than $cur."

author=$(jq -r .author.login <<<"$release")
if [[ $author != 'github-actions[bot]' ]]; then
	echo "::error::$tag was published by $author, not upstream's release workflow. Review it by hand."
	exit 1
fi

published=$(date -d "$(jq -r .published_at <<<"$release")" +%s)
age_hours=$((($(date +%s) - published) / 3600))
if ((age_hours < min_age_hours)); then
	echo "$tag is ${age_hours}h old; waiting until it is ${min_age_hours}h old."
	exit 0
fi

sha=$(api "repos/$upstream/commits/$tag" | jq -r .sha)
runs=$(api "repos/$upstream/commits/$sha/check-runs?per_page=100")
pending=$(jq -r '[.check_runs[] | select(.status != "completed") | .name] | join(", ")' <<<"$runs")
if [[ -n $pending ]]; then
	echo "Upstream checks on $tag still running: $pending"
	exit 0
fi
failed=$(jq -r '[.check_runs[]
	| select(.conclusion as $c | ["success", "skipped", "neutral"] | index($c) | not)
	| "\(.name) (\(.conclusion))"] | join(", ")' <<<"$runs")
if [[ -n $failed ]]; then
	echo "::error::Upstream checks failed on $tag: $failed"
	exit 1
fi
for check in "${required_checks[@]}"; do
	if ! jq -e --arg n "$check" 'any(.check_runs[]; .name == $n and .conclusion == "success")' <<<"$runs" >/dev/null; then
		echo "::error::Upstream check '$check' did not run on $tag. Upstream CI may have changed; review the gate in update.sh."
		exit 1
	fi
done
echo "Upstream checks on $tag passed: $(jq -r '[.check_runs[].name] | join(", ")' <<<"$runs")"

digest() {
	local d
	d=$(jq -r --arg n "$1" '.assets[] | select(.name == $n) | .digest // empty' <<<"$release")
	if [[ $d != sha256:* ]]; then
		echo "::error::Release $tag has no sha256 digest for asset $1." >&2
		return 1
	fi
	echo "${d#sha256:}"
}
bin_sum=$(digest xdg-desktop-portal-gtk4-linux-x86_64.tar.gz)
src_sum=$(digest "xdg-desktop-portal-gtk4-$ver.tar.gz")

sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
BIN_SUM=$bin_sum SRC_SUM=$src_sum perl -0pi -e \
	's/^sha256sums=\([^)]*\)/sha256sums=(\x27$ENV{BIN_SUM}\x27\n            \x27$ENV{SRC_SUM}\x27)/m' PKGBUILD
grep -q "$bin_sum" PKGBUILD && grep -q "$src_sum" PKGBUILD

echo "Bumped to $ver."
[[ -n ${COMMIT_MSG_FILE:-} ]] && echo "Update to $ver" >"$COMMIT_MSG_FILE"
exit 0
