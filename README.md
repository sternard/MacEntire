# MacEntire

MacEntire is a deliberately small macOS menu bar launcher for a fixed collection of local Assistant apps.

Unlike Mac Assistant, it does not scan the computer for repositories. The supported repositories are declared in [`Packages/packages.txt`](Packages/packages.txt), and every managed checkout lives beside it in `Packages/`.

## How it works

Open the menu bar item and choose **Sync Packages**. MacEntire will:

1. Clone missing repositories into `Packages/<repository-name>`.
2. Fast-forward-pull repositories that are already present.
3. Refuse to update a checkout with local changes, an unexpected `origin` remote, or the wrong configured branch.
4. Show apps containing `scripts/run-app.sh` as launchable menu items.

MacEntire never searches other folders, deletes package files, resets branches, or overwrites local changes.

## Package list

Add one GitHub repository per line to `Packages/packages.txt`. Private repositories work when the current user has Git access:

```text
https://github.com/sternard/Storage-Assistant
https://github.com/sternard/HEIC-to-JPEG -b develop
```

Markdown links are also accepted, so this is equivalent:

```text
[Storage Assistant](https://github.com/sternard/Storage-Assistant)
```

Append `-b branch-name` to clone and track a specific branch. The suffix also works after a Markdown link:

```text
[Storage Assistant](https://github.com/sternard/Storage-Assistant) -b feature/new-ui
```

When a branch is configured, MacEntire clones only that branch. An existing checkout must already be on the configured branch; MacEntire will report a mismatch instead of switching branches automatically.

Blank lines and lines beginning with `#` or `//` are ignored. Repository folders inside `Packages/` remain independent Git repositories and are ignored by MacEntire itself.

Each managed app must provide:

```text
scripts/run-app.sh
```

## Run locally

```sh
./scripts/run-app.sh
```

The script builds a local `.app` bundle and opens MacEntire as a menu bar app. It does not add a Dock icon.

Set `MACENTIRE_SKIP_OPEN=1` to build and validate the app bundle without opening it.

## Install

```sh
./scripts/install-app.sh
```

This installs and opens `~/Applications/MacEntire.app`. Use **Start on Login** in the MacEntire menu to control whether macOS opens it when you sign in.

The installed app continues to manage the `Packages/` directory beside this source checkout, so rerun the installer after moving the MacEntire repository.

## Tests

```sh
swift test
```

## License

MacEntire is available under the MIT License. See [`LICENSE`](LICENSE).
