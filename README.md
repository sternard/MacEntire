# MacEntire

MacEntire is a deliberately small macOS menu bar launcher for a fixed collection of local apps.

The shared package catalog lives in [`Packages/packages.txt`](Packages/packages.txt). Managed repositories are cloned into the same `Packages/` directory and remain independent Git checkouts.

## How synchronization works

Choose **Sync Packages** from the menu bar. MacEntire will:

1. Update its own clean checkout from the current branch on `origin` using a fast-forward-only merge.
2. Re-read the updated `Packages/packages.txt`.
3. Exclude repositories listed in the local `Packages/ignore.txt`.
4. Clone missing repositories and fast-forward existing clean checkouts.

MacEntire refuses to update a checkout with local changes, an unexpected `origin`, a detached HEAD, the wrong configured branch, or an update that would overwrite an ignored file. If the MacEntire checkout itself has local changes, its self-update is skipped but package synchronization continues using the current catalog.

When MacEntire's source changes, the currently running app continues the synchronization and displays a reminder to rerun the installer. A newly fetched package catalog is used immediately without restarting.

## Package catalog

Add one GitHub repository per line to `Packages/packages.txt`:

```text
https://github.com/sternard/Storage-Assistant
https://github.com/sternard/HEIC-to-JPEG -b develop
```

Markdown links are also accepted:

```text
[Storage Assistant](https://github.com/sternard/Storage-Assistant)
```

Append `-b branch-name` to clone and track a specific branch. The name must identify a branch on the remote; a same-named tag is not accepted. Existing checkouts must already be on the configured branch, and MacEntire reports a mismatch instead of switching branches automatically.

Blank lines and lines beginning with `#` or `//` are ignored.

## Per-computer exclusions

`Packages/packages.txt` is the shared upstream catalog and should stay unchanged on individual computers. To skip a package on one computer, add the same repository URL to `Packages/ignore.txt`:

```text
// Packages/ignore.txt
https://github.com/sternard/Screen-Swap
```

`ignore.txt` accepts the same raw URLs, Markdown links, comments, and optional branch suffixes as `packages.txt`. It is ignored by Git, so MacEntire can update the shared catalog without changing local exclusions.

Ignoring a package prevents it from appearing or synchronizing. Entries are matched by GitHub owner and repository, so the same repository name under a different owner is not excluded. An existing checkout is left untouched and can be restored by removing its entry from `ignore.txt`.

Each active package must provide:

```text
scripts/run-app.sh
```

## Run locally

```sh
./scripts/run-app.sh
```

Set `MACENTIRE_SKIP_OPEN=1` to build and validate the app bundle without opening it.

## Install

```sh
./scripts/install-app.sh
```

This installs and opens `~/Applications/MacEntire.app`. Use **Start on Login** in the MacEntire menu to control whether macOS opens it when you sign in.

## Tests

```sh
swift test
```

## License

MacEntire is available under the MIT License. See [`LICENSE`](LICENSE).
