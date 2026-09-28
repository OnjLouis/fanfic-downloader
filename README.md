# Fanfic Downloader

Fanfic Downloader is an accessible Windows downloader and EPUB cleaner for Archive of Our Own, FanFiction.net, and FictionPress. It accepts supported links from the command line or clipboard, retries previously failed stories, and avoids duplicate queue entries when different chapters of the same story are supplied.

## What's New in 1.0.7

- When AO3 blocks its direct EPUB and HTML downloads, an optional FicHub fallback checks both the reported source and the EPUB against the requested AO3 work ID. It never substitutes a work based on a similar title.
- The terminal reports AO3 HTTP errors, the FicHub chapter count, and the cache date. A cached copy remains in the failed-URL queue until AO3 can verify a direct download.
- The downloader remembers the highest AO3 chapter count in `user\chapter-history.json`, even after an EPUB leaves the output folder. It skips cached copies with fewer or equal chapters and does not repeatedly reopen an unchanged copy.
- Cached AO3 copies without a known chapter count stay queued by default. `allow_unverified_ao3_cache=true` permits these potentially incomplete copies; `use_fichub_for_ao3=false` disables the fallback entirely.

## Earlier Changes in 1.0.6

- Fixed post-download EPUB inspection in a clean Windows PowerShell session by loading ZIP support before reading the archive.
- EPUB preparation now repairs harmless whitespace before XML declarations and reports malformed XML without dumping chapter text into the terminal.
- The terminal shows story names where possible, or a short AO3 work or series label, while complete URLs and diagnostic details remain in the log.
- Temporary preparation folders are removed after success, failure, and timeout, and diagnostic-only startup no longer creates one.

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
- `user\failed-urls.txt` contains the persistent retry queue.
- `user\chapter-history.json` contains the highest known AO3 chapter count for each work. Keep this file when moving books or cleaning logs.
- `user\logs` contains only the current and immediately previous downloader diagnostics.
- `user\downloads` is the default output folder.
- `user\updates` contains update state, one rollback snapshot, and the two most recent updater logs.

Updates never replace or package the `user` folder. Older installations with settings or logs at the program root migrate them automatically. Conflicting files are retained under `user\migration-conflicts` instead of being overwritten.

The retry queue is kept outside `user\logs`, so the entire logs folder can be deleted without losing queued story URLs. Old per-run logs and abandoned temporary queue files are removed automatically.

The terminal uses story names where the source URL provides one and short AO3 work or series labels otherwise. Full URLs and detailed subprocess errors remain in the diagnostic log, while fatal terminal output is limited to a concise summary and the log location.

FicHub is a cache, not an independent source of AO3 updates. When AO3 denies access, the downloader cannot confirm whether FicHub has the latest chapter or text. The downloader checks cached chapter counts against its persistent history and any EPUB still in the output folder. Existing books outside that folder are not imported automatically, so a fresh or upgraded installation may not have a known count yet. Without a known count, it keeps the URL queued unless `allow_unverified_ao3_cache=true`; even then, a saved cached copy does not remove the URL from the retry queue. It never substitutes a different work based on a similar title.

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
