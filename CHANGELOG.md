# Changelog

## Unreleased

- Docs: with a committed `.kx.json` that has no app ID, deleting the app means the next run
  creates it again; the quick start says how to stop that (remove `.kx.json` or the workflow,
  or commit the `.kx.json` that `kx link` writes once the app exists).

## 1.0.0

First release.

- Docs: the quick start uses `actions/checkout@v7`, so runs show no Node 20 deprecation
  notice, and starts by saying how the first run gets its app: create it first, or let the
  first run create it from a committed `.kx.json`.
