# Fanfic Downloader

Fanfic Downloader is an accessible Windows downloader and EPUB cleaner for Archive of Our Own, FanFiction.net, and FictionPress. It accepts supported links from the command line or clipboard, retries previously failed stories, and avoids duplicate queue entries when different chapters of the same story are supplied.

## Installation

1. Download the latest `FanficDownloader` ZIP from GitHub Releases.
2. Extract the complete archive to a folder you can write to.
3. Run `Install Fanfic Downloader.cmd` once.
4. Run `Download AO3 with FanFicFare.cmd` whenever a supported URL is in the clipboard.

Python 3.10 or later is required for the FanFicFare fallback. The installer creates a private environment named `fanficfare_env` and installs the tested dependency versions without changing the system Python environment.

## User Data

All installation-specific data lives under `user`:

- `user\downloader.ini` contains downloader settings.
- `user\fanficfare_personal.ini` contains FanFicFare settings.
- `user\logs` contains diagnostic logs and the failed URL queue.
- `user\downloads` is the default output folder.
- `user\updates` contains update state and the two most recent rollback snapshots.

Updates never replace or package the `user` folder. Older installations with settings or logs at the program root migrate them automatically. Conflicting files are retained under `user\migration-conflicts` instead of being overwritten.

## Updates

The downloader checks GitHub no more than once every 24 hours. When a newer stable release is available, it offers to install it before continuing. `Update Fanfic Downloader.cmd` performs a manual check.

Every update is staged and validated before installation. The updater requires a valid RSA-signed manifest, verifies the package SHA-256 hash, rejects undeclared or unsafe archive entries, backs up managed files, parse-checks PowerShell scripts, and rolls back a partial replacement. An update cannot declare `user` as a managed path.

## Configuration

The supplied `downloader.example.ini` and `fanficfare.example.ini` document the initial settings. The installer copies them into `user` only when the corresponding personal file does not already exist.

Update prompts can be disabled without disabling manual updates:

```ini
[updates]
check_for_updates=true
prompt_to_install=false
```

## Maintainer Notes

The repository contains source and public configuration examples only. Do not commit `user`, `fanficfare_env`, downloaded stories, cookies, logs, release staging, or private signing material.

## License

Fanfic Downloader is released under the MIT License. FanFicFare and the supported websites remain subject to their own licenses and terms.
