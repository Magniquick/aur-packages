# aur-packages

AUR packages I maintain, with the CI that keeps them updated.

| Package | AUR |
| --- | --- |
| [xdg-desktop-portal-gtk4-bin](xdg-desktop-portal-gtk4-bin) | https://aur.archlinux.org/packages/xdg-desktop-portal-gtk4-bin |

## How updates work

Each package directory holds the `PKGBUILD` and `.SRCINFO` that get pushed to
the AUR, plus the scripts CI runs. This repo is the source of truth, and the AUR
repo is overwritten to match it.

A daily workflow, also run on every push to `main`:

1. Runs the package's `update.sh`. For xdg-desktop-portal-gtk4-bin, a new
   upstream release is taken only once it is 24 hours old, was published by
   upstream's release workflow, and every upstream check run on the tagged
   commit passed. The checksums come from GitHub's asset digests.
2. Builds the package with `makepkg` in an `archlinux:latest` container,
   installs it, and runs the package's `e2e.sh` against the installed files.
3. Commits any change back to this repo and pushes `PKGBUILD` and `.SRCINFO`
   to the AUR with a deploy key kept in the `AUR_SSH_PRIVATE_KEY` secret.

A release that fails a gate fails the workflow and waits for a manual look.

### xdg-desktop-portal-gtk4-bin e2e checks

Upstream's tests run the portal code in-process with the UI stubbed out.
`e2e.sh` checks the installed package instead:

- the D-Bus service file activates `/usr/lib/xdg-desktop-portal-gtk4`
- every interface listed in `gtk4.portal` is exported
- `xdg-desktop-portal` routes `Settings` calls to the backend
- a `FileChooser.OpenFile` request opens a dialog on headless weston, stays
  open until `Request.Close`, and the backend survives it

## Running locally

```sh
./xdg-desktop-portal-gtk4-bin/update.sh     # bump if a release passes the gates
./scripts/build.sh xdg-desktop-portal-gtk4-bin   # build, install, e2e
```

`build.sh` installs the package with `sudo pacman -U`, so run it in a container
or VM if you do not want it on the host.
