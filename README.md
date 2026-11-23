# Kubernetix deploy action

`Kubernetix-AI/deploy` deploys your repository to [Kubernetix](https://platform.kubernetix.ai)
on every push to your main branch and gives you the live URL.

It runs in your own GitHub Actions runner: it installs a pinned, checksum-verified
[kx](https://github.com/Kubernetix-AI/kx) and runs `kx deploy --github`, which builds your
Dockerfile, pushes the image to your Kubernetix registry, deploys it and waits until it is live.
The commit gets a "Kubernetix / production" status, the run gets a summary, and the job's
environment links to the live app.

## Quick start

1. **Create the app first.** Run `kx deploy` once from your computer (it offers to create the
   app), or create it in the Kubernetix dashboard. With the `app:` input, the Action deploys to
   an app that already exists. To let the first run create the app instead, run
   `kx link <name>` once, commit the `.kx.json` it writes, and leave out the `app:` input; that
   run needs a token that can deploy every app (Settings → API tokens) instead of the deploy
   token below, which only reaches the app it was made for. If you later delete the app, the next
   CI run creates it again; remove `.kx.json` (or the workflow) first.
2. **Create a deploy token.** In the Kubernetix dashboard, open your app → **Deploy** →
   **Deploy from GitHub** → **Create deploy token**, and copy it.
3. **Save it in a `production` environment** limited to your main branch
   ([how](#set-up-the-production-environment)), as the secret `KX_TOKEN`.
4. **Add the workflow** below as `.github/workflows/kubernetix.yml` on your main branch, with
   your app's name in both places, and push.

```yaml
name: Deploy to Kubernetix
on:
  push: { branches: [main] }
concurrency: { group: kubernetix-shop-api }
permissions: { contents: read, statuses: write }
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: { name: production, url: "${{ steps.kx.outputs.url }}" }
    steps:
      - uses: actions/checkout@v7
      - id: kx
        uses: Kubernetix-AI/deploy@v1
        with: { app: shop-api, token: "${{ secrets.KX_TOKEN }}" }
```

The dashboard's Deploy tab shows this workflow with your app and branch filled in, ready to
copy.

A new app gets the port in your Dockerfile's first `EXPOSE` line (8080 without one), and a
version is live once your app answers HTTP requests on `/` at that port. If a new version's
container keeps crashing or doesn't answer, the run shows a warning with the likely cause and
the container's last log lines after a couple of minutes, and keeps waiting: the job fails only
if Kubernetix gives up on the version or the `timeout` passes. The version before it keeps
serving.

The `concurrency` group serializes deploys of one app: a running deploy is never canceled, and
if several pushes arrive while it runs, only the newest one deploys next. GitHub drops the other
waiting runs, and a dropped tag push's image never gets its version tag: re-run that workflow, or
give tag pushes a group of their own (`group: kubernetix-shop-api-${{ github.ref_type }}`). Run one deploy per
app at a time; a deploy started elsewhere (from a laptop or the dashboard) at the same moment
can race this one.

## Set up the production environment

Keep `KX_TOKEN` in an environment that only your deploy branch can use, not in a repository
secret. A workflow on any branch can read a repository secret, so anyone who can push a branch
could print it. An environment secret is only given to jobs that run on the branches you allow.

1. In your repository, open **Settings** → **Environments** → **New environment**, name it
   `production` and choose **Configure environment**.
2. Under **Deployment branches and tags**, choose **Selected branches and tags**, then **Add
   deployment branch or tag rule**, and enter your deploy branch (for example `main`).
3. Under **Environment secrets**, choose **Add environment secret**, name it `KX_TOKEN` and
   paste the deploy token.
4. Optional: add **Required reviewers** if someone should approve each deploy, for example to
   run a database change by hand first.

The workflow's `environment: { name: production, ... }` line is what gives the job that secret.
If you name the environment something else, set the Action's `environment` input to the same
name so the commit status matches.

Deploy tokens made on an app's Deploy tab can only deploy that app, and expire after a year.
To rotate one, create a new token, replace the secret, then revoke the old token in the
dashboard.

## Inputs

| Input | What it does | Default |
|---|---|---|
| `token` | **Required.** A Kubernetix deploy token (`kx_...`). Pass it from a secret. | |
| `app` | The app to deploy. | the app in `.kx.json`, or the one app the token can deploy |
| `path` | The folder to build, relative to the repository root. | `.` |
| `dockerfile` | The Dockerfile to build with, relative to the repository root (a name inside `path`, such as `Dockerfile.prod`, works too). | `Dockerfile` in `path` |
| `image` | Deploy this image instead of building, for example `registry.kubernetix.ai/acme-corp/shop-api@sha256:...`. Don't combine it with `path` or `dockerfile`. | |
| `repository` | The repository in your organization's registry to push to, `registry.kubernetix.ai/<org>/<repository>`, for example `shop-frontend` ([more](#image-tags-and-repository)). Needs kx 1.1.0 or later. | the repository in `.kx.json`, or the app's name |
| `environment` | The name in the commit status, `Kubernetix / <environment>`. Use the job's environment name. | `production` |
| `wait` | `true` waits until the deploy is live; `false` stops once it has started. | `true` |
| `timeout` | How long to wait for the deploy to go live. The default outlasts Kubernetix's own retries of a version that doesn't get ready (3 attempts of 5 minutes). | `18m` |
| `github-token` | The token used to set the commit status. It needs `statuses: write`. | `${{ github.token }}` |
| `kx-version` | The kx version to run. Each release of this Action pins one and carries its checksums; only those versions can be used. | `1.0.0` <!-- pinned-kx-version --> |

## Outputs

| Output | What it holds |
|---|---|
| `url` | The app's live URL. |
| `deployment-id` | The ID of the Kubernetix deployment. |
| `version` | The app version this deploy created, for example `v15`. |
| `image` | The image that was deployed, by digest. |

To use an output in a later step, pass it through `env:`, never straight into `run:`:

```yaml
      - name: Smoke test
        env: { URL: "${{ steps.kx.outputs.url }}" }
        run: curl -fsS "$URL"
```

## More examples

A service in a subfolder, with its own Dockerfile:

```yaml
        with:
          app: billing-worker
          path: services/billing
          dockerfile: services/billing/Dockerfile.prod
          token: "${{ secrets.KX_TOKEN }}"
```

An image built by an earlier step or another workflow:

```yaml
        with:
          app: shop-api
          image: registry.kubernetix.ai/acme-corp/shop-api@sha256:3f9c...
          token: "${{ secrets.KX_TOKEN }}"
```

Images that live in a repository not named after the app:

```yaml
        with:
          app: shop-api
          repository: shop-frontend
          token: "${{ secrets.KX_TOKEN }}"
```

A "Run workflow" button for manual deploys: add `workflow_dispatch:` under `on:`.

## Image tags and repository

kx builds the checked-out folder as it is, including any files earlier steps of the job wrote
into it, and pushes the image under the checked-out commit's first 12 characters, such as
`3f9c2a1b7d4e` (`git rev-parse HEAD`; the commit GitHub names only goes into the commit status
and summary, and kx 1.1.0 and later say so when it isn't the one checked out). With kx 1.1.0 or
later, when the commit has a git tag that looks like a version (`v1.4.0` or `1.4.0`, optionally
with a pre-release such as `-rc.1`; the highest if there are several), the image gets that
version too, without the `v`: `1.4.0`. The run log's Pushed line and the job summary show it.

kx never moves a version tag. If `1.4.0` already holds an image from another commit (or one
that doesn't say which commit it is), the job fails and deploys nothing (before building when kx
could look first, otherwise right after pushing). If it
holds an earlier build of the same commit (a re-run of the job, or a second run for one tagged
push), the tag stays there, the log says "The version tag 1.4.0 stays on the earlier build of
this commit.", and the new build deploys. Registry tags can be written by anyone who can push to
your organization's registry, so a version tag is a convenient label, not a guarantee: kx always
deploys the image it just pushed, by its digest, and a tag someone else took can only stop a
deploy, never change what it ships. The `concurrency` group in the quick start keeps runs from
racing for a tag.

`actions/checkout` fetches one commit and no tags by default, so before kx (1.1.0 or later)
builds, the Action asks `origin` for the tags that point at the commit and fetches the version
tags among them that the checkout doesn't have.
That uses the checkout's credentials, which `actions/checkout` keeps unless you set
`persist-credentials: false`; if it can't, the run log says so and the image gets no version
tag. Either of these also works:

- deploy when a version tag is pushed (the checkout then has the tag):

  ```yaml
  on:
    push: { tags: ["v*"] }
  ```

- or fetch the tags in the checkout yourself:

  ```yaml
        - uses: actions/checkout@v7
          with: { fetch-depth: 0 }   # or: fetch-tags: true
  ```

kx 1.1.0 and later also label each image with the commit it was built from
(`org.opencontainers.image.revision`) and where the build sits in the repository.

The image goes to `registry.kubernetix.ai/<org>/<app>` unless the `repository` input, or
`"repository"` in a committed `.kx.json` (for the app it links), names another repository in
your organization's registry, such as the one your images have always been in. The name is
lowercase letters and digits with single `.`, `_` or `-` between them and `/` between parts,
without the registry's address or the organization, and with no part called `tags` (Kubernetix's
image routes would read it as a tag). A deploy token's Push images permission
covers every repository in the organization's registry, so the app's own deploy token can push
there.

## Which events deploy

- Pull request runs never deploy: `pull_request`, `pull_request_target`,
  `pull_request_review`, `pull_request_review_comment` and `merge_group` print "Pull request
  previews aren't available yet, so kx skips pull and merge request runs." and succeed without
  deploying, so unmerged code never reaches production (and a workflow that also runs on pull
  requests stays green).
- Every other event runs the whole deploy of the commit the workflow checked out: `push`,
  `workflow_dispatch`, and also `release`, `schedule`, `workflow_run` or any other event you add
  under `on:`. List only the events you want to deploy from. Re-running a job deploys that
  commit again.

## What GitHub shows

All of these use the job's own `GITHUB_TOKEN`; the Action needs no GitHub App or webhook.

- **Commit status** "Kubernetix / production": "Building", then "Deploying v15", then "Live in
  3m 14s" linking to the app, or the first line of the error.
- **Deployment**: the job's `environment:` line makes GitHub record a production deployment
  with a "View deployment" link to the URL kx outputs.
- **Job summary**: app, version, URL, image digest, the image's tags (kx 1.1.0 or later),
  commit, duration and the rollback command.
- **Annotations and outputs**: an error annotation with both lines of any error, and the outputs
  above.

If the job fails, the summary says whether an earlier version is still serving. If the token
can't set the commit status (for example `statuses: write` is missing), you get a warning and
the deploy carries on. If the run times out or is canceled, a Kubernetix deploy that already
started keeps going; check it with `kx status`.

## Pin the Action to a commit

`@v1` follows every 1.x release of this Action. To run exactly the code you reviewed, pin the
full commit SHA of a release and keep its version as a comment:

```yaml
        uses: Kubernetix-AI/deploy@<40-character commit SHA> # v1.0.0
```

Find the SHA on the repository's
[Tags](https://github.com/Kubernetix-AI/deploy/tags) page, or with
`git ls-remote --tags https://github.com/Kubernetix-AI/deploy v1.0.0` (use the line ending
in `^{}`). Pinning the Action pins kx too: each release of the Action installs one kx version and
checks it against the SHA-256 checksums committed in this repository. Dependabot can keep a
pinned SHA up to date:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
```

## Troubleshooting

Every error has two lines: what happened, then the fix. These are the ones you are most likely
to see. For the Action's own errors the table shows both lines exactly as printed; for kx's
errors it adds what to change in the workflow.

| What happened | What to do |
|---|---|
| The token input is empty, so this workflow can't deploy. | Save a deploy token as the KX_TOKEN secret of the production environment, and give the job environment: production. (The job must also run on a branch that environment allows.) |
| The KX_TOKEN secret holds a token that expired on 9 Feb 2027. | Create a new deploy token on the app's Deploy tab and replace the `KX_TOKEN` secret. |
| This token stopped working because the person who created it is no longer a member of acme-corp. | Ask an admin of acme-corp for a new token: Settings → API tokens. |
| This token can only deploy shop-api, and you asked to deploy web. | Set `app` to the app the token belongs to, or save a token for web. |
| This token can't upload images. | Create a token with Push images on the app's Deploy tab, or deploy an image that's already pushed with the `image` input. |
| There's no Dockerfile in /home/runner/work/shop-api/shop-api. | Set `path` to the folder with your Dockerfile, or set `dockerfile`. |
| acme-corp has used all 5 deploys the Free plan includes today; more are available at 00:00 UTC (in 3 h 12 min). | Wait, or upgrade for more deploys a day: platform.kubernetix.ai/plans |
| This token has uploaded images too often in the last hour. | kx waits up to about 6 minutes for this on its own. If it needs longer, wait the minutes it says, then re-run the job. |
| The token in the KX_TOKEN secret doesn't have the Read permission, which kx deploy needs. | Create a deploy token on the app's Deploy tab (it has Deploy, Read and Push images) and replace the `KX_TOKEN` secret. |
| shop-api v15 didn't go live: its container kept crashing or didn't answer health checks on / at port 8080. Version 14 is still serving. | The log lines in the run usually say why (kx shows them with an earlier warning). Make the app start and answer on `/` at the port in your Dockerfile's `EXPOSE` line. |
| shop-api v15 didn't go live: your container is crashing on start. Version 14 is still serving. | The 20 log lines above it usually say why. See more with `kx logs --deployment v15`. |
| shop-api v15 is still starting after 18 minutes, so kx stopped waiting; the deploy continues. | Check on it with `kx status`, or raise `timeout`. |
| Kubernetix-AI/deploy runs on Linux runners only, and this job runs on macOS. | Use runs-on: ubuntu-latest for the job that deploys. |
| This release of Kubernetix-AI/deploy can't install kx 1.2.0, because it has no checksums for it. | Use a kx version it has checksums for (1.0.0), or a newer release of the Action. |
| kx 1.0.0 is no longer available from GitHub, so this release of Kubernetix-AI/deploy can't install it. | Use a newer release of the Action, such as Kubernetix-AI/deploy@v1, or remove kx-version. |
| The kx 1.0.0 download doesn't match the checksum committed in Kubernetix-AI/deploy, so it wasn't installed. | Re-run the job. If it happens again, report it: https://github.com/Kubernetix-AI/deploy/security/advisories/new |
| kx builds your app with Docker, and Docker isn't installed on this computer. | Use a runner with Docker, such as `ubuntu-latest`, or deploy a prebuilt `image`. |
| registry.kubernetix.ai/acme-corp/shop-api:1.4.0 already holds another image, so kx left the tag alone and deployed nothing. | The tag names an image from another commit, or one pushed without kx's commit label (by hand or by kx 1.0). Tag a new version, or, if you know the image the tag holds (anyone who can push to the organization's registry can write a tag), deploy it with the `image` input and the digest the error names (`registry.kubernetix.ai/acme-corp/shop-api@sha256:...`). |
| kx couldn't check whether registry.kubernetix.ai/acme-corp/shop-api:1.4.0 already exists, so nothing was deployed. | Re-run the job. |
| The repository input needs kx 1.1.0 or later, and this job runs an older kx. | Use a release of Kubernetix-AI/deploy that pins kx 1.1.0 or later (or set kx-version to one), or remove the repository input. |
| The Action couldn't get this commit's tags from origin, so the image gets no version tag; to include them, set fetch-depth: 0 in actions/checkout. | Not an error: the deploy goes on with the commit's tag. Keep the checkout's credentials, set `fetch-depth: 0`, or deploy on tag pushes ([more](#image-tags-and-repository)). |

## Security

- **kx is pinned and verified.** The Action downloads one kx version over HTTPS from the kx
  releases on GitHub and installs it only if its SHA-256 matches the checksum committed in this
  repository. Those checksums are written when the Action is released, after checking each kx
  file's build provenance against the kx release workflow. There is no switch to skip the
  check.
- **Inputs are data.** Every input reaches the Action's scripts through environment variables
  and becomes a single `--flag=value` argument; no input is ever pasted into shell code. A test
  runs the Action with inputs such as `$(touch pwned)` and backticks and checks that nothing
  ran.
- **The token** goes to kx through the environment, is masked in the log, is only sent to the
  Kubernetix API over HTTPS, and kx prints at most its first 11 characters. Keep it in an
  environment secret limited to your deploy branch.
- **Least privilege.** The workflow needs only `contents: read` and `statuses: write`. The
  registry credential kx uses to push is minted for the run, masked, and expires within an hour.
- **Pull requests never deploy**, so code that isn't merged can't reach production. Other
  events deploy, so list only the ones you deploy from.
- **Only GitHub and Kubernetix** are contacted: GitHub for the kx download and the commit
  status, your repository's `origin` for the commit's tags (with the checkout's own
  credentials), and `https://platform.kubernetix.ai` and `registry.kubernetix.ai` for the
  deploy.

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). Copyright 2026 Nandan, Inc.
