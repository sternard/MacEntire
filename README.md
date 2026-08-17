# MacEntire

MacEntire is a deliberately small macOS menu bar launcher for a fixed collection of local Assistant apps.

Unlike Mac Assistant, it does not scan the computer for repositories. The supported repositories are declared in [`packages.txt`](packages.txt), and every managed checkout lives in `Packages/` inside this repository.

## How it works

Open the menu bar item and choose **Sync Packages**. MacEntire will:

1. Clone missing repositories into `Packages/<repository-name>`.
2. Fast-forward-pull repositories that are already present.
3. Refuse to update a checkout with local changes or an unexpected `origin` remote.
4. Show apps containing `scripts/run-app.sh` as launchable menu items.

MacEntire never searches other folders, deletes package files, resets branches, or overwrites local changes.

## Package list

Add one GitHub repository per line. Private repositories work when the current user has Git access:

```text
https://github.com/sternard/Storage-Assistant
https://github.com/sternard/HEIC-to-JPEG
```

Markdown links are also accepted, so this is equivalent:

```text
[Storage Assistant](https://github.com/sternard/Storage-Assistant)
```

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

## Install at login

```sh
./scripts/install-app.sh
```

This installs `~/Applications/MacEntire.app` and creates `~/Library/LaunchAgents/local.macentire.plist`. The installed app continues to manage the `Packages/` directory beside this source checkout, so rerun the installer after moving the MacEntire repository.

## Tests

```sh
swift test
```

## License

MacEntire is available under the MIT License. See [`LICENSE`](LICENSE).
