# kx checksums

One file per kx version this Action can install, named `<version>.txt` (for example
`1.0.0.txt`). Each file is the `checksums.txt` of that kx release on
[github.com/Kubernetix-AI/kx/releases](https://github.com/Kubernetix-AI/kx/releases): one
`<sha256>  <archive>` line for each of the six release archives.

`scripts/install-kx.sh` installs kx only when the downloaded archive matches its line here, and
refuses any version that has no file in this folder.

**Never write or edit these files by hand.** `scripts/publish-action.sh` writes them when the
Action is released, after checking that the release's `checksums.txt` lists exactly the six
archives, that every archive matches it, and that every file carries a build provenance
attestation from the kx release workflow. A committed file is never changed afterwards.

The one exception is **withdrawing** a kx version that must no longer be installed: its file is
deleted, in a commit of its own, and a new release of the Action is published without it (see
`docs/RELEASING.md`, "Withdrawing a kx version"). Files are deleted, never rewritten.
