# Changelog

All notable changes to Mac OS Migrator are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The script files carry their own internal version numbers in their header comments — entries below correlate to those, in the form `migrate-apps.sh v4.4 / migrate-home.sh v1.4`.

## [Unreleased]

_Nothing yet._

## migrate-apps.sh v4.4 / migrate-home.sh v1.4 — 2026-05-19

### Added

- **Optional Finder tagging.** Both scripts now ask at the mode prompt for a tag name (default `Migrated`, blank to skip). Every successfully migrated item gets the chosen tag applied via the same `com.apple.metadata:_kMDItemUserTags` xattr Finder uses, so you can spotlight `tag:Migrated` afterwards or filter from the Finder sidebar. Implementation uses `xattr` + `plutil` — no external dependencies. Tag-write failures are non-fatal (the move has already succeeded by the time tagging is attempted).
- **`migrate-home.sh` also tags intermediate directories** that `mkdir -p` creates during a move (`Documents/Imported/`, `Imported/YYYY/`, `Keys and Certificates/Downloads/`, etc.). Walks up the destination path before the move and tags each new component, stopping at `DST_HOME` or any pre-existing directory. The whole imported tree surfaces in Spotlight, not just the leaves; pre-existing user directories are left alone.

### Documentation

- README's "Finder tagging (optional)" section now spells out exactly what does and doesn't get tagged.

## migrate-apps.sh v4.3 / migrate-home.sh v1.3 — 2026-05-19

### Changed

- **`move_with_verify` now captures `mv`'s stderr** into the log, so failures show the actual OS error (`Permission denied`, `Operation not permitted`, etc.) instead of a bare `✗ mv failed`.
- **When `mv` returns non-zero, the function checks whether the destination actually exists.** macOS `mv` across volumes is internally `cp -R` followed by `rm -rf`; if the `cp` phase succeeds but the `rm` phase trips on signature-protected files (`_CodeSignature/CodeResources` resists `rm` even for the owning user), `mv` returns non-zero but the destination is intact. Previously the script reported these as failures; now they're correctly logged as `⚠ copied, source cleanup failed — destination intact` and counted as successes, with a one-liner shown for manual source cleanup if desired.

### Documentation

- README's new **"Before you run with `execute`: grant Terminal Full Disk Access"** section explains the TCC requirement up front, with the exact error message users will see if they skip the FDA grant. Surfacing the prerequisite at the top of the docs rather than as a footnote.

## migrate-apps.sh v4.2 — 2026-05-19

### Fixed

- **PlistBuddy error-leakage on broken `.app` bundles.** `get_bundle_id` and `get_display_name` now verify `Info.plist` exists before invoking PlistBuddy. Some broken bundles ship without a readable `Info.plist`; PlistBuddy then writes a `File Doesn't Exist, Will Create: ...` message to STDOUT (not stderr — long-standing PlistBuddy quirk), and that error string was being captured as the app's bundle ID and display name. The guard ensures missing-plist apps get an honest `<unreadable>` indicator instead.

## migrate-home.sh v1.2 — 2026-05-19

### Added

- **Archive-on-conflict for Mac standard libraries (step 3).** macOS often auto-creates empty placeholder versions of `~/Music/Music`, `~/Pictures/Photos Library.photoslibrary`, `~/Library/Mail`, etc. on first login. Previously the script silently skipped these because the destination "already existed". It now offers to archive the old copy to `<folder>/Imported/YYYY/<library>` instead, so your old data isn't lost just because macOS made a placeholder. Libraries inside `Pictures/Music/Movies/Documents/Desktop/Downloads` archive within their parent; libraries inside `~/Library/` (Mail, Messages, Notes, etc.) archive to `~/Documents/Imported/Old Library Data/YYYY/`.
- **Expanded key/cert search (step 4).** Extensions now include PGP material (`.asc`, `.gpg`) and other key formats (`.ppk`, `.bks`, `.jks`, `.keystore`, `.kdbx`) in addition to the original X.509 / PKCS#12 forms. Output folder renamed from `Imported-Certs` to `Keys and Certificates`. Relative paths from `$SRC_HOME` are preserved inside that folder so identically-named files from different folders don't collide and bundle structures like `ultra.tblk/` stay readable.
- **"Probably Junk" routing (step 5).** Top-level items matching `$RECYCLE.BIN`, `Thumbs.db`, `desktop.ini`, `.DS_Store`, `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems`, `.Trashes` are routed to `<folder>/Imported/Probably Junk/` instead of a year folder. Mass-deletable in one click later.

### Changed

- **Date-mode selection moved earlier** so step 3 archive paths and step 5 year-sort use the same date type.
- **Step 5 skips items already queued in step 3** — no more double-handling of library folders that step 3 chose to archive.

## migrate-home.sh v1.1 — 2026-05-19

### Fixed

- **Pipe-character bug in the plan.** Plan was stored as joined `"src|dst|label"` strings; filenames containing `|` (encountered in the wild: `"My Account | Billing.pdf"`, `"About Us | UNASA Tucson.pdf"`) broke the `IFS=|` split at execute time, resulting in malformed paths that would silently fail to migrate. Switched to three parallel arrays `PLAN_SRC` / `PLAN_DST` / `PLAN_LABEL` so filenames with any character except `/` and NUL survive round-trip cleanly.

## migrate-apps.sh v4.1 — 2026-05-19

### Changed

- **Auto-discover mode by default.** The `APPS=()` array is empty out of the box, triggering auto-discovery of every `.app` in the source Applications folder. The per-app prompt now defaults to **N** in auto-discover mode (you press `y` to include), and to **Y** in curated mode (hardcoded `APPS` list — you press `n` to skip). Safer default for the auto-discover case, where there may be 50–100+ candidate apps.

## Initial public release — 2026-05-19

First publicly published version on GitHub. Bundle:

- **`migrate-apps.sh`** (Phase 1, internal v4) — interactive `.app` migration with per-app prompts, plan summary, dry-run by default. Reads bundle IDs live from each `Info.plist`. Auto-skips apps already installed at `/Applications`, `/System/Applications`, or `/System/Applications/Utilities`. Probes `Application Support`, `Preferences`, `Containers`, and `Group Containers`, with Group Containers matched against on-disk folder names by bundle-ID substring (accommodating the Team-ID prefixes embedded in `Group Containers/<TeamID>.<group-id>/` folder names that aren't derivable from the bundle ID alone).
- **`migrate-home.sh`** (Phase 2, internal v1) — seven-step home-folder migration covering Mac standard libraries (Photos, Music, Logic, FCP, iMovie, Mail, Messages, Notes, Voice Memos, Safari), security materials (SSH/GPG/certs with optional iCloud-Keychain-aware `login.keychain-db` handling), year-sorted loose files in standard folders, non-standard top-level home folders, and dotfiles. All interactive, dry-run by default, with a plan-and-confirm gate before any `mv` runs.
- **`migrate-apps.command` / `migrate-home.command`** — double-clickable Finder launchers that open Terminal automatically, run the matching `.sh`, and keep the window open after exit so you can read the result.
- **`README.md`**, **`MIGRATION_PLAN.md`** — user-facing documentation.
- **`LICENSE`** (MIT), **`.gitignore`**.
