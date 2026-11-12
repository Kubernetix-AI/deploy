# Releasing the Action

Workflows use this Action by a tag: `@v1` (the major tag, which moves) or `@v1.2.3` (a release
tag, which never moves), or by a commit SHA. A release of the Action is a commit on `main` that
pins one kx version, plus its tags. `scripts/publish-action.sh` does the whole release.

## Versions

- A release tag `vX.Y.Z` is created once and **never moved, deleted or reused**: people pin
  it, and some pin the commit it points at.
- The major tag `vX` points at the newest stable `vX.Y.Z`. It moves forward with each release
  and moves backwards only for a rollback (below).
- By default the Action's version is the kx version it pins: Action `v1.2.0` runs kx 1.2.0.
  When the Action changes but kx doesn't (for example a fix in `install-kx.sh`), release it with
  the next patch version and the same kx: `--action-version 1.2.1 1.2.0`.
- A change that could break a workflow that works with `@v1` today (removing or renaming an
  input or output, changing a default in a way that changes what deploys) needs a new major
  version, `v2`. Leave `v1` where it is.
- Release candidates (`vX.Y.Z-rc.N`) get their own tag and never move the major tag.

## Before the first release

Do these once, after the repository is made public and before the first tag (the kx
repository's `docs/RELEASING.md` has the full list, including the organization's two-factor
requirement):

1. **Apply the rulesets** in `.github/rulesets/` (see [Protecting tags and main](#protecting-tags-and-main)).
2. **Turn on private vulnerability reporting** (Settings → Code security → Private
   vulnerability reporting). `SECURITY.md` and the Action's error messages link to it.

## Releasing

Do this after the kx release is published and verified (see the kx repository's
`docs/RELEASING.md`).

1. Start from a clean, up-to-date `main` in a clone of this repository, as a repository admin
   (the push goes straight to `main`, which only admins may do) with two-factor authentication
   and `gh` signed in (it verifies the kx attestations):

   ```sh
   git switch main && git pull --ff-only
   ```

2. **Dry run.** It downloads the kx release's `checksums.txt` and six archives, checks that
   `checksums.txt` lists exactly the six archives and that each matches, verifies every file's
   build provenance with `gh attestation verify` (built by
   `Kubernetix-AI/kx/.github/workflows/release.yml` from tag `v1.2.0`, on a GitHub-hosted
   runner), then shows the new `checksums/1.2.0.txt`, the change to the default `kx-version`
   in `action.yml` and `README.md`, and the tags it would create or move. It changes nothing.

   ```sh
   scripts/publish-action.sh 1.2.0
   ```

3. **Publish.** The same checks, then it writes `checksums/1.2.0.txt`, makes 1.2.0 the default,
   commits "chore(release): pin kx 1.2.0" on `main`, creates the annotated tag `v1.2.0`, moves
   `v1` to it, and pushes `main` and both tags in one atomic push:

   ```sh
   scripts/publish-action.sh --push 1.2.0
   ```

   `--commit` does everything except the push, if you'd like to look first; it prints the push
   command to run afterwards.

   `--skip-attestations` and the `KX_RELEASE_DIR` test setting work only for dry runs and for
   a clone whose `origin` is a local folder (the script's tests). With a real `origin`,
   `--commit` and `--push` always verify the release files and their provenance.

4. **Check it.** CI's "Install every pinned kx" job downloads and verifies every pinned version,
   on x64 and ARM64, on each push to `main`. Then run a workflow that uses
   `Kubernetix-AI/deploy@v1` in a scratch repository and confirm the log says
   "Installed kx 1.2.0".
5. **Optional: GitHub Marketplace.** The script creates tags, not GitHub Releases. To list the
   Action on the Marketplace, draft a release from the new tag on the repository's Releases
   page and tick "Publish this Action to the GitHub Marketplace".

The script refuses to run from another branch or with uncommitted changes, refuses a tag that
already exists, never rewrites a committed checksums file, and moves the major tag only when
the new version is the newest stable release of that major.

`checksums/` files are written only by this script. Never edit them by hand, and never commit
a checksums file for a kx version that isn't released. The only other change ever made to
`checksums/` is deleting a file to withdraw a version (below).

## Moving the major tag

The script moves `vX` for you. To move it by hand (only for a rollback):

```sh
git tag -f -a v1 -m "Kubernetix-AI/deploy 1.1.0 (rollback)" "v1.1.0^{commit}"
git push --force origin refs/tags/v1
```

## Rollback

If a release of the Action is bad, either because of the Action or the kx it pins, start here,
before anything is done to the kx release:

1. **Move `v1` back** to the previous good release tag, as above. Workflows on `@v1` use it on
   their next run. Release tags stay where they are.
2. **Then release a fix** as the next patch version. To go back to an older kx, publish it under
   a new Action version: `scripts/publish-action.sh --push --action-version 1.2.1 1.1.0`. Its
   checksums file is already committed and is reused as it is.

Never delete or move a `vX.Y.Z` tag.

## Withdrawing a kx version

Withdraw a kx version only when it must never be installed again, for example a harmful build
whose release files are going to be removed. Workflows on Action releases that pin it then stop
with "kx X is no longer available from GitHub" and are told to use a newer release of the Action.

1. Make sure `v1` and the default `kx-version` on `main` don't use it: roll back as above first.
2. Delete its checksums file in a commit of its own, through a pull request:
   `git rm checksums/1.2.3.txt`, committed as "chore(release): withdraw kx 1.2.3".
3. Publish a new Action version from `main` with the current good kx, so `v1` moves to a release
   without the withdrawn file:
   `scripts/publish-action.sh --push --action-version 1.2.5 1.2.2`.
4. Only then remove the kx release's files (the kx repository's `docs/RELEASING.md`,
   "Rollback").

## Protecting tags and main

Customers' workflows trust this repository's tags and `main`, so every member of the
Kubernetix-AI organization must use two-factor authentication, and three rulesets are kept as
code in `.github/rulesets/`:

- **Release tags**: only repository admins may create, move or delete `v*` tags. Admins bypass
  it, so `publish-action.sh` can create release tags and move `v1`.
- **main**: nobody can delete `main` or force-push to it. There is no bypass, and
  `publish-action.sh` only ever fast-forwards `main`.
- **main: pull requests**: changes reach `main` through a pull request with the "CI" check
  passing (reported by GitHub Actions). Repository admins bypass it, which is what lets
  `publish-action.sh --push` push its release commit straight to `main`.

Once the repository is public (GitHub's free plan enforces rulesets only on public
repositories), apply them as a repository admin with the kx repository's script, from a clone of
this repository next to a clone of kx (a dry run first, then `--apply`; run it again after
changing a file):

```sh
../kx/scripts/apply-rulesets.sh --repo Kubernetix-AI/deploy --dir .github/rulesets
../kx/scripts/apply-rulesets.sh --repo Kubernetix-AI/deploy --dir .github/rulesets --apply
```
