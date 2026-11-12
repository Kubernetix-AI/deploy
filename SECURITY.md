# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: open the **Security** tab of this
repository and choose **Report a vulnerability**. Don't open a public issue, pull request or
discussion for a security problem.

Tell us what you found, how to reproduce it, and what an attacker could do with it. We will
acknowledge your report, keep you updated while we fix it, and credit you when we publish the
fix unless you'd rather stay anonymous.

Never include a real token in a report. If you have shared one by mistake, revoke it in the
Kubernetix dashboard under Settings → API tokens, or with `kx token revoke <prefix>`.

## Scope

In scope:

- `action.yml` and the scripts in `scripts/`;
- the kx checksums in `checksums/` and how the Action uses them to verify kx;
- this repository's release tags (`v1`, `v1.0.0`, ...).

The `kx` command line itself is in [Kubernetix-AI/kx](https://github.com/Kubernetix-AI/kx);
report problems with it there, or here if you're not sure. Problems with the Kubernetix platform
(the dashboard or the API at `https://platform.kubernetix.ai`) can be reported the same way.

Out of scope: problems that need an attacker who can already change your workflow files,
secrets or runner, denial of service through volume, and reports produced only by automated
scanners without a demonstrated impact.

## How the Action protects you

- **Verified kx.** The Action installs only kx versions whose SHA-256 checksums are committed in
  `checksums/`, downloads them from the kx releases on GitHub over HTTPS, and refuses an
  archive that doesn't match. Checksums are committed only by `scripts/publish-action.sh`,
  which first checks the kx release's build provenance attestations, and are never changed
  afterwards (a version that must not be installed any more is withdrawn by deleting its file
  in a new release of the Action).
- **No shell injection.** Inputs reach the scripts only through environment variables and are
  passed to kx as single `--flag=value` arguments. The CI tests run the Action with hostile
  inputs (`$(...)`, backticks, quotes, line breaks) against a stand-in kx and fail if anything
  runs.
- **Secrets.** The token is passed to kx in the environment, never on the command line, and is
  masked in the log. kx prints at most the first 11 characters of a token, masks the short-lived
  registry credential it mints, and sends the token only to the Kubernetix API over HTTPS.
- **Permissions.** The Action needs `contents: read` and `statuses: write`, and uses the job's
  own `GITHUB_TOKEN` only to set the commit status.
- **Pull requests never deploy.** kx refuses to deploy from any event other than `push` and
  `workflow_dispatch`.
- **Tags.** Release tags are created only by maintainers with two-factor authentication. Pin
  the Action to a full commit SHA if you want to review every change before you run it (see the
  README).

## Supported versions

Security fixes go into the latest release, and the major tag (`v1`) moves to it. Workflows that
use `@v1` get fixes automatically; workflows pinned to a commit SHA should update the SHA.
