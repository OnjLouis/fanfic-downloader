# Fanfic Downloader

Fanfic Downloader is an accessible Windows downloader and EPUB cleaner for Archive of Our Own, FanFiction.net, and FictionPress. It accepts supported links from the command line or clipboard, retries previously failed stories, and avoids duplicate queue entries when different chapters of the same story are supplied.

## What's New in 1.0.10

- Filename history is read as UTF-8 on Windows PowerShell, so punctuation such as em dashes no longer becomes corrupted and grows the history on each save.
- The downloader stops before loading a filename history larger than 16 MiB. It does not rewrite damaged history or remove anything from the failed-URL queue.

## Earlier Changes in 1.0.9

- New installations use the main AO3 FanFicFare route first. Upgrades preserve existing settings: set `prefer_native=false` and `prefer_ao3_mirror=false` under `[download]` to select this route. A site restriction can still prevent a download; this release does not bypass HTTP 403 or 525 errors.
- The updater no longer creates replacement `.new` files beside the live scripts, so a failed replacement does not leave those files behind. An update started with an older updater still uses that older updater's rollback behaviour.

- FanFicFare attempts each story in a separate subprocess. A crashed, timed-out, or rejected story does not prevent later stories from being attempted. The four-minute attempt timeout applies per story, not to the whole batch. Progress identifies each story without displaying its full URL.
- A batch offers one AO3 login retry for unfinished stories only. Already retrieved EPUBs are not downloaded again for that retry, and they can still be saved and opened when another story's login is cancelled or rejected. Only validated, successfully saved works leave the retry queue.
- Interactive runs offer a masked AO3 login prompt when FanFicFare reports missing or rejected credentials, not only when a login request returns 403. The downloader retries once and deletes its temporary login configuration afterward; credentials are not added to your permanent settings. Redirected or unattended runs do not prompt and keep affected works queued. A login failure is not success even when FanFicFare exits with code zero.
- Preparation workers no longer rotate the main download log. Error runs retain the complete download and conversion history; successful runs still remove their log. Logs record the script hash to identify the exact local build.
- Browser imports use built-in .NET SHA-256 instead of depending on a PowerShell hashing module. Successful-import deletion still requires an unchanged original and a successfully published output.
- The primary FanFicFare route explicitly disables inherited mirror settings and automatic chapter-tab opening, while preserving any passive browser-cache configuration. It has passed real-world single-story and batch downloads, including a login-required work, followed by continued use. HTTP 403 and 525 failures can still occur; this does not guarantee access to every work.
- `prefer_ao3_mirror=true` sends AO3 works directly to FanFicFare's alternate AO3 domain instead of retrying the blocked native URLs. Choose either documented domain with `ao3_mirror_domain`. FanFicFare browser-cache mode and automatic page opening are disabled for this route, so it does not open chapter tabs. The option is off in the portable example until verified on your connection.
- `Download Clipboard Only.cmd` processes a copied link without adding the existing failed-URL queue to that run. It does not erase the queue, and a new failure is still saved there.
- Native AO3 downloads now use a work-ID URL without a fabricated `updated_at` value. This is an experimental response to blocked direct downloads; it does not guarantee that AO3 will accept the request.
- `Import Browser EPUBs.cmd` discovers AO3 and FicHub FanFiction.net/FictionPress EPUBs in the configured browser download folder without needing URLs on the clipboard or in the failed queue. It makes no site requests. Other EPUBs, including ordinary purchased books, are left alone.
- `delete_imported_browser_epubs=true` removes only a matching browser EPUB after its prepared output has been saved and its URL cleared from the failed queue. It is off by default; failed, unmatched, and changed downloads remain in the browser folder.
- When FicHub has no newer AO3 copy, the normal downloader now tries its FanFicFare backup instead of stopping at the cache check. This does not guarantee access when AO3 is returning HTTP 403.
- AO3 EPUBs now reuse the filename of a matching book already in the output folder. Once saved, the name is remembered in `user\filename-history.json`, so switching between native, FicHub, FanFicFare, and browser-import routes does not rename the same work after the old file has been moved.
- An existing filename belonging to another story is not overwritten. If filename history is damaged, the downloader stops before downloading instead of silently changing names.

## Earlier Changes in 1.0.8

- Optional `browser_epub_folder` imports supported story EPUBs that you downloaded manually in your browser. The downloader verifies AO3 or FicHub source attribution, requires a newer copy than the saved or recorded book, applies the usual cleanup, and removes a successfully imported work from the failed-URL queue. It copies the EPUB; the browser download remains untouched unless `delete_imported_browser_epubs=true`.
- This does not bypass AO3's HTTP restrictions or make Chrome download a work automatically.

## Earlier Changes in 1.0.7

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
- `user\filename-history.json` remembers AO3 EPUB filenames across download routes and after books leave the output folder. Keep it with the other user data.
- `user\logs` contains only the current and immediately previous downloader diagnostics.
- `user\downloads` is the default output folder.
- `user\updates` contains update state, one rollback snapshot, and the two most recent updater logs.

Updates never replace or package the `user` folder. Older installations with settings or logs at the program root migrate them automatically. Conflicting files are retained under `user\migration-conflicts` instead of being overwritten.

The retry queue is kept outside `user\logs`, so the entire logs folder can be deleted without losing queued story URLs. Old per-run logs and abandoned temporary queue files are removed automatically.

The terminal uses story names where the source URL provides one and short AO3 work or series labels otherwise. Full URLs and detailed subprocess errors remain in the diagnostic log, while fatal terminal output is limited to a concise summary and the log location.

FicHub is a cache, not an independent source of AO3 updates. When AO3 denies access, the downloader cannot confirm whether FicHub has the latest chapter or text. The downloader checks cached chapter counts against its persistent history and any EPUB still in the output folder. Existing books outside that folder are not imported automatically unless `browser_epub_folder` is configured; a fresh or upgraded installation may not have a known count yet. Without a known count, it keeps the URL queued unless `allow_unverified_ao3_cache=true`; even then, a saved cached copy does not remove the URL from the retry queue. It never substitutes a different work based on a similar title.

## Updates

The downloader checks GitHub no more than once every 24 hours. When a newer stable release is available, it offers to install it before continuing. `Update Fanfic Downloader.cmd` performs a manual check.

Every update is staged and validated before installation. The updater requires a valid RSA-signed manifest, verifies the package SHA-256 hash, rejects undeclared or unsafe archive entries, backs up managed files, parse-checks PowerShell scripts, and rolls back a partial replacement. An update cannot declare `user` as a managed path.

### Recovering Filename History

If startup says filename history could not be read, run `Update Fanfic Downloader.cmd` directly. The separate updater can run even when the downloader stops before its automatic update check.

Install 1.0.10 or later before retrying. The patch prevents further encoding damage, but does not repair existing damage. If startup still stops, close the downloader, move `user\filename-history.json` somewhere safe, and restore a known-good copy if available. Without a backup, the downloader starts a new history and can reuse names from matching EPUBs still in the output folder. Books that have already been moved out of that folder may get new filenames, and your reader may treat them as new books. Keep the moved history for possible recovery. Do not move or delete `user\failed-urls.txt`; it is a separate file.

## Configuration

The supplied `downloader.example.ini` and `fanficfare.example.ini` document the initial settings. The installer copies them into `user` only when the corresponding personal file does not already exist.

New installations use FanFicFare directly against the main AO3 domain. Existing configurations are preserved during updates: select this route with `prefer_native=false` and `prefer_ao3_mirror=false` under `[download]` in `user\downloader.ini`. This preserves passive browser-cache settings from your FanFicFare configuration but never opens chapter tabs automatically. Cache use can only help with pages already available locally; it does not promise a complete or current download. The usual chapter-count guards still apply. These settings do not change FanFiction.net's FicHub route.

An optional alternate-domain trial uses `prefer_ao3_mirror=true` and `ao3_mirror_domain=archiveofourown.gay` (the default) or `archive.transformativeworks.org`. The latter cannot log in through FanFicFare, so restricted works may fail. This retains the canonical AO3 work URL for chapter tracking and EPUB naming, requires FanFicFare, and disables browser-cache access for the mirror route. Both domains can return 403 too; a failing mirror should not be treated as a reliable fallback. Unavailable works stay queued. Browser EPUB importing below remains the local alternative.

For a single-story trial, copy its work URL and double-click `Download Clipboard Only.cmd`. This skips retrying earlier failures once; the normal launcher continues to process clipboard and failed-URL links together.

If FanFicFare reports that AO3 login is required or was rejected, an interactive run asks for your username and a masked password, then retries unfinished stories once. Leave the username or password blank to cancel; failed works remain queued while successfully retrieved EPUBs are still prepared and opened. The temporary login configuration stays in the run's temporary staging directory and is removed afterward; this login is not remembered between runs. For unattended use, configure `username:` and `password:` under `[archiveofourown.org]` in your private `user\fanficfare_personal.ini`. That file stores credentials as plain text; keep it private and do not include it in shared packages. Login can still fail if AO3 blocks the request, even with correct credentials.

To import story EPUBs downloaded manually in any browser, set `browser_epub_folder` to that browser's download directory in `user\downloader.ini`. This path is optional and has no machine-specific default; leave it blank to disable importing. The downloader discovers an AO3 work from its original-work attribution, or a FanFiction.net/FictionPress story from a FicHub introduction with an original-source link. URLs on the clipboard or in the failed queue are no longer required for those recognized exports. Incidental links elsewhere in a book do not qualify; unrecognized EPUBs, such as Kobo purchases, stay untouched. An AO3 import must meet the recorded chapter count and improve on any existing output copy; FanFiction.net and FictionPress imports must improve on any existing output copy and reach the chapter number in a queued URL. The original file remains by default. Set `delete_imported_browser_epubs=true` under `[download]` to delete it only after the final EPUB is saved and the URL leaves the failed queue. Only `.epub` files are imported this way; other formats use the ordinary download routes and do not receive EPUB-specific cleanup or template styling.

```ini
[paths]
browser_epub_folder=C:\Users\YourName\Downloads

[download]
delete_imported_browser_epubs=false
```

Imported EPUBs go through the same configured EPUB cleanup and stylesheet replacement as EPUBs obtained by the other routes. The source EPUB's internal structure can still differ. The downloader keeps a stable output filename for each AO3 work, which helps readers that associate history with a path, but it cannot guarantee that a saved line or chapter offset will match after the book's text changes. Paperback also uses a content fingerprint when it first sees a path; a missing prior history record cannot be reconstructed from the EPUB filename alone.

The browser folder is a manual fallback, not a requirement for normal downloads. The downloader now generates a work-ID download URL without a timestamp, but AO3 may still block a scripted request even when the same work downloads in a browser. The script does not automatically drive a browser or read its download history.

After downloading a supported story EPUB into that folder, double-click `Import Browser EPUBs.cmd` to process it without retrying blocked site requests. The command discovers recognized EPUBs itself and also checks URLs from the clipboard and failed queue; books without matching files remain queued. It uses the same EPUB preparation and reader-opening settings as the normal downloader, and optionally deletes each successfully imported browser copy. An equally complete AO3 EPUB can be imported when the previous output copy has been moved away; a copy with fewer chapters than the recorded count, or no improvement over an existing output copy, is rejected. If no matching or newer EPUB is present, it reports that rather than attempting an online download.

AO3 uses `updated_at` on its own generated download links as a cache-busting value derived from the work's update time. It is not a login token. The downloader omits that value rather than guessing the current time. This has not yet been verified to fix HTTP 403. Exporting browser cookies into FanFicFare is also not a reliable remedy for a browser challenge; the downloader does not request or store browser credentials for this import mode.

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
