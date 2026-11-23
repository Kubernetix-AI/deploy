# Changelog

## 1.1.0 (unreleased)

These need kx 1.1.0 or later; the release that adds them pins it.

- A `repository` input pushes the image to `registry.kubernetix.ai/<org>/<repository>`
  instead of the repository named after the app. With an older kx the step says it needs
  kx 1.1.0.
- Before kx builds, the Action fetches the commit's version tags from `origin` that the
  checkout doesn't have, so kx can give the image the version too (`actions/checkout`
  fetches no tags by default). It never fails the job, and skips this with a kx that has no
  version tags.
- Docs: version tags (how the checkout gets them, what happens on a re-run or a second run
  for the same commit, that a tag someone else took can only stop a deploy), the
  `repository` input, and that the `concurrency` group can drop a waiting tag push's run.
- Docs: with a committed `.kx.json` that has no app ID, deleting the app means the next run
  creates it again; to stop that, remove `.kx.json` (or the workflow), or commit the `.kx.json`
  that `kx link` writes once the app exists. kx 1.1.0 says in the log when a run creates the
  app this way.

## 1.0.0

First release.

- Docs: the quick start uses `actions/checkout@v7`, so runs show no Node 20 deprecation
  notice, and starts by saying how the first run gets its app: create it first, or let the
  first run create it from a committed `.kx.json`.
