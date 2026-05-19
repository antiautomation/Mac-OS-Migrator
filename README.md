# Mac OS Migrator

> A pair of interactive shell scripts for hand-rolling a macOS migration, app by app and folder by folder, with nothing moving until you say so.

## The story

I wiped my Mac, then sat down to set up the new install the way I actually wanted, and stalled.

Two options stared back at me. **Migration Assistant**, Apple's built-in tool, would happily drag everything over — but the whole reason I wiped in the first place was that "everything" had quietly accumulated over the years: caches I'd never cleared, abandoned dev environments, half-installed frameworks, dotfiles I no longer remembered the purpose of, plugins for apps I no longer used, login items pointing at binaries that no longer existed. Migration Assistant doesn't ask. It brings it all. By the time it finishes, the new install is the old install wearing a clean shirt.

The other option was **doing it by hand** — `cp -R`'ing `~/Documents`, `~/Pictures`, certain apps from `/Applications`, picking through `~/Library` for the bits I actually cared about. Tedious, error-prone, and easy to miss something important: the `Group Containers/<TeamID>.<group-id>/` folder that actually holds an app's settings, the sandbox `Containers/` directory where Mac App Store apps keep all their state, the `~/.ssh` keys I'd forget to chmod after copying, the PGP keys someone tucked into `~/Documents` years ago.

So I built this.

`migrate-apps.sh` and `migrate-home.sh` are two interactive bash scripts that walk you through a macOS migration end to end. They default to dry-run. They probe each item, show you what was found and where it would land, and ask. They handle the awkward corners — bundle IDs read live from each `Info.plist`, Group Containers matched against actual on-disk folder names, sandboxed app data routed correctly, iCloud-Keychain users spared a pointless encrypted-blob move, broken `.app` bundles handled without polluting the summary. You hold the line on what crosses over.

If your goal is a fresh start that's actually fresh, this is the migration tool you reach for.

## What's in the box

| File | Phase | Handles |
|---|---|---|
| `migrate-apps.sh` | 1 | `.app` bundles + per-app data (`Application Support`, `Preferences`, `Containers`, `Group Containers`) |
| `migrate-home.sh` | 2 | Home folder contents — Mac standard libraries, SSH/GPG/certs, year-sorted loose files, other top-level folders, dotfiles |
| `MIGRATION_PLAN.md` | — | In-depth walkthrough, design notes, per-app caveats, FAQ |

Run them in order: apps first, then home.

## Requirements

- macOS (tested on Tahoe / macOS 26).
- The old Mac's data volume attached at a known mount point (commonly `/Volumes/Old Data` after wipe-and-install).
- A Time Machine backup is **strongly recommended** before running with `execute`. The scripts use `mv`, not `cp` — files leave the source as they land on the destination.
- Built-in bash 3.2 is enough. No external dependencies.

## Quick start

You can drive both phases from your terminal, or you can double-click. Pick whichever you'd rather.

### From the terminal

```bash
chmod +x migrate-apps.sh migrate-home.sh

# Phase 1 — applications. Always dry-run first.
./migrate-apps.sh                # answer prompts, choose 'dry-run', review the plan
./migrate-apps.sh                # again, this time choose 'execute'

# Phase 2 — home folder
./migrate-home.sh
./migrate-home.sh                # execute
```

### From Finder (double-click)

Each phase has a `.command` companion file that opens Terminal automatically, runs the matching script, and keeps the window open at the end so you can read the result. Drop the whole folder where you want it (e.g. `~/Downloads`), then:

1. Double-click `migrate-apps.command` — answer prompts, choose `dry-run`, review.
2. Double-click `migrate-apps.command` again — this time choose `execute`.
3. Repeat with `migrate-home.command`.

**First-run caveat for downloaded files.** If you downloaded the repo zip or cloned over HTTPS, macOS attaches a quarantine attribute to the files and will block the `.command` from running with a "Apple cannot check this for malicious software" warning the first time you double-click. Two fixes:

```bash
# Either: strip the quarantine attribute from the whole folder
xattr -dr com.apple.quarantine "/path/to/Mac OS Migrator"

# Or: right-click the .command file → Open → confirm in the dialog.
# After that, double-click works normally.
```

If `chmod +x` got lost in transit, the .command files include a self-heal that re-chmods the .sh scripts on each run, so you only need to make the .command executable once.

### Logs

Every prompt, answer, and operation is logged to `~/migration-*.log` and `~/migration-home-*.log`. Useful for reviewing what happened, debugging skipped items, or filing issues.

## Shape of an interactive run

Each script follows the same pattern:

1. **Confirm paths** — source and destination, with sensible defaults you can override.
2. **Choose mode** — dry-run (default) or execute.
3. **Walk through items** — y/n per app or per library, with `a` to approve all remaining, `q` to stop prompting, `?` for help.
4. **Plan summary** — every queued operation as `[label] src -> dst`.
5. **Final confirmation** — one last "are you sure" before any `mv` happens.
6. **Execute** — moves run with verification; destinations that already exist are never clobbered.

## Highlights

### `migrate-apps.sh` — Phase 1

- **Auto-discovers** every `.app` in the source Applications folder; you say y/n per app.
- Reads `CFBundleIdentifier` and `CFBundleName` live from each `Info.plist` — no hardcoded guesses.
- **Auto-skips** apps already installed at `/Applications`, `/System/Applications`, or `/System/Applications/Utilities` (so Apple-bundled apps don't get duplicated).
- For each approved app, moves the bundle **and** matching per-app data:
  - `~/Library/Application Support/<app>`
  - `~/Library/Preferences/<bundle-id>.plist`
  - `~/Library/Containers/<bundle-id>/` (sandboxed apps)
  - `~/Library/Group Containers/<TeamID>.<group-id>/` — matched by **bundle-ID substring** against actual folder names, since the on-disk folder name embeds the developer's Team ID prefix that isn't trivially derivable from the bundle ID alone.
- Optional curated mode: hardcode a list of `.app` filenames in the script's `APPS=()` array to limit scope; per-app prompt then defaults to "yes" instead of "no".

### `migrate-home.sh` — Phase 2

- **Mac standard libraries** detected by their well-known filenames — Photos, Music, Logic's `Audio Music Apps/`, FCP `.fcpbundle`, iMovie, Mail, Messages, Calendars, Contacts, Notes, Safari, Voice Memos.
- **Archive-on-conflict logic**: macOS auto-creates empty placeholder folders for many libraries on first login. If the canonical destination is already occupied, the script offers to archive the old library to `<folder>/Imported/YYYY/` instead of silently skipping. So your old Music library lands at `~/Music/Imported/2019/Music` rather than getting lost.
- **iCloud-Keychain-aware**: if you confirm you use iCloud Keychain, the script skips the encrypted `login.keychain-db` migration entirely (it'll re-sync from the cloud). If you don't, it offers to place the old keychain alongside the new one and prints Keychain Access import instructions.
- **SSH / GPG / certs**: moves `~/.ssh/` and `~/.gnupg/`; recursively scans Desktop / Documents / Downloads for keys, certificates, PGP material, and other credential formats (`.p12 .pfx .pem .crt .cer .der .key .asc .gpg .ppk .bks .jks .keystore .kdbx`); consolidates them under `~/Documents/Keys and Certificates/` preserving relative paths so name collisions and bundle structures don't break.
- **Year-sorted loose files**: top-level items in each of Documents/Desktop/Downloads/Pictures/Movies/Music get filed into `<folder>/Imported/YYYY/<item>` based on a date type you pick (modified or created). Items already queued in step 3 are skipped automatically.
- **"Probably Junk" routing**: filenames matching `$RECYCLE.BIN`, `Thumbs.db`, `desktop.ini`, `.DS_Store`, `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems`, `.Trashes` go to `<folder>/Imported/Probably Junk/` instead of dated buckets, so you can mass-delete with one click later.
- **Other top-level folders and dotfiles**: every non-standard folder (`~/GitHub`, `~/Projects`, etc.) and every dotfile/dotdir gets a y/n prompt.

## Customizing the scripts for your install

Each script has a clearly-marked `CONFIGURATION` block at the top. Common edits:

**`migrate-apps.sh`:**
```bash
DEFAULT_SRC_VOL="/Volumes/Old Data"   # change if your old volume mounts elsewhere
DEFAULT_SRC_APPS="$DEFAULT_SRC_VOL/Applications"
DEFAULT_SRC_LIB="$DEFAULT_SRC_VOL/Users/$(whoami)/Library"
DEFAULT_DST_APPS="/Applications"
DEFAULT_DST_LIB="$HOME/Library"

APPS=()    # empty = auto-discover. Or list specific .app filenames here.
```

**`migrate-home.sh`:**
```bash
DEFAULT_SRC_VOL="/Volumes/Old Data"
DEFAULT_SRC_HOME="$DEFAULT_SRC_VOL/Users/$(whoami)"
DEFAULT_DST_HOME="$HOME"

# Plus tunable lists: STANDARD_FOLDERS, KNOWN_LIBRARIES, LIBRARY_EXTENSIONS,
# KEY_EXTENSIONS, JUNK_PATTERNS — see MIGRATION_PLAN.md for what each does.
```

## Safety properties

- **Dry-run by default.** The script defaults to printing what it *would* do. You have to explicitly type `execute` to perform real moves, and that prompt has a second confirmation.
- **No clobber.** Every move checks that the destination doesn't already exist before touching anything. If it does, the move is skipped (libraries get the archive option instead — see above).
- **Verify-after-mv.** Each `mv` checks the destination exists post-operation before logging success.
- **Parallel-array plan.** Internal data structures store source / destination / label in parallel arrays rather than joined strings, so filenames with any character (pipes, tabs, anything except `/` and NUL) round-trip cleanly.
- **No keychain meddling.** The script never touches your new login keychain. The old one is placed alongside it for manual import via Keychain Access, never auto-merged.

## What it does NOT do

- **Doesn't migrate `/Library/Audio/` or other `/Library/` system-wide assets.** Logic loops, plug-ins, and Final Cut effects libraries installed system-wide are outside the home folder and not touched. Migrate those manually if you want them.
- **Doesn't unlock or merge keychains.** Old `login.keychain-db` is placed alongside the new one; you use Keychain Access to drag items across.
- **Doesn't import SSH key passphrases.** The script moves `~/.ssh/` and prints the `ssh-add --apple-use-keychain ~/.ssh/id_*` command to run after — you run it.
- **Doesn't migrate WireGuard tunnel private keys.** Those live in the macOS Keychain, not in the WireGuard app's Container. You'll re-import `.conf` files.
- **Doesn't recurse into subfolders for year-sort.** A subfolder gets filed by its own mtime/btime, preserving its internal structure. Files inside subfolders don't get individually year-sorted.

## Project layout

```
mac-os-migrator/
├── README.md
├── MIGRATION_PLAN.md       # detailed walkthrough, design notes, per-app caveats, FAQ
├── LICENSE                 # MIT
├── .gitignore
├── migrate-apps.sh         # Phase 1 — CLI entry point
├── migrate-apps.command    # Phase 1 — double-click entry point (wraps the .sh)
├── migrate-home.sh         # Phase 2 — CLI entry point
└── migrate-home.command    # Phase 2 — double-click entry point (wraps the .sh)
```

The `.command` wrappers are thin: they `cd` to their own directory, ensure the matching `.sh` is executable, run it, and keep the Terminal window open at exit. All the actual logic lives in the `.sh` files.

## Contributing

Issues and PRs welcome. Some areas where the project could grow:

- Additional known-library detection (DaVinci Resolve, Lightroom Classic catalogs, OBS scene collections, etc.).
- An adjunct step for Apple Pro apps' `/Library/Audio/` and `/Library/Application Support/Logic|GarageBand/` system assets.
- Better handling for keychain merge (with a clear warning that any automated approach has trade-offs).
- A `--non-interactive` mode that reads decisions from a config file for repeatable runs.
- Windows-on-Mac junk detection beyond the current pattern list.

If you find an app whose Group Container isn't matched correctly, capture the bundle ID + the actual Group Container folder name on your system and file an issue — the substring-match heuristic may need an additional pattern or a manual override map.

## License

Released under the MIT License — see `LICENSE` for details.

## Disclaimer

You run this on your own machine, at your own risk. The author makes no warranty that it will work for your setup, your version of macOS, or your specific combination of installed apps. Always have a current Time Machine backup before running with `execute`. The scripts default to dry-run; use that to verify the plan before letting anything move.
