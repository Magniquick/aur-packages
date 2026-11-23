#!/usr/bin/env bash
# Make the AUR repo for a package match this repo's copy of it, and push.
# Does nothing when they already match, so it also retries a failed push.
#
# Env: AUR_SSH_PRIVATE_KEY, AUR_GIT_NAME, AUR_GIT_EMAIL; optional
# COMMIT_MSG_FILE (otherwise the last commit subject touching the package).
set -euo pipefail
pkg=${1:?usage: aur-sync.sh <package-dir>}
root=$(git rev-parse --show-toplevel)
cd "$root"

key=$(mktemp)
trap 'rm -f "$key"' EXIT
printf '%s\n' "$AUR_SSH_PRIVATE_KEY" >"$key"
chmod 600 "$key"
export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$root/scripts/aur_known_hosts"

# PKGBUILD, .SRCINFO, .gitignore if present, and any local (non-URL) sources.
mapfile -t files < <(
	printf '%s\n' PKGBUILD .SRCINFO
	[[ -f $pkg/.gitignore ]] && echo .gitignore
	sed -n 's/^\tsource\(_[a-z0-9_]*\)\? = //p' "$pkg/.SRCINFO" | sed 's/^[^:]*:://' | grep -v '://' || true
)

aur=$(mktemp -d)
git clone --quiet "ssh://aur@aur.archlinux.org/$pkg.git" "$aur"
git -C "$aur" ls-files -z | while IFS= read -r -d '' f; do
	printf '%s\n' "${files[@]}" | grep -qxF -- "$f" || git -C "$aur" rm --quiet -- "$f"
done
for f in "${files[@]}"; do
	cp -- "$pkg/$f" "$aur/$f"
	git -C "$aur" add -- "$f"
done

if git -C "$aur" diff --cached --quiet; then
	echo "AUR $pkg already matches."
	exit 0
fi
if [[ -s ${COMMIT_MSG_FILE:-} ]]; then
	msg=$(cat "$COMMIT_MSG_FILE")
else
	msg=$(git log -1 --format=%s -- "$pkg")
	msg=${msg#"$pkg: "}
fi
git -C "$aur" diff --cached --stat
git -C "$aur" -c user.name="$AUR_GIT_NAME" -c user.email="$AUR_GIT_EMAIL" commit --quiet -m "$msg"
git -C "$aur" push --quiet origin HEAD:master
echo "Pushed $pkg to the AUR: $msg"
