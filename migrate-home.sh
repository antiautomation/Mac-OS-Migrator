#!/bin/bash
# ============================================================================
#  migrate-home.sh  (v1.4 — Finder tagging, intermediate dirs included)
#
#  Changes vs v1.3:
#    - Optional Finder tag applied to every migrated item, so you can find
#      and review everything that came across in Finder afterward. Step 2
#      now asks for a tag name (default "Migrated", blank disables).
#      Implemented via xattr + plutil — no external dependencies.
#    - Intermediate directories created by 'mkdir -p' (e.g. Documents/
#      Imported/, Imported/YYYY/, Keys and Certificates/Downloads/) are
#      also tagged so Spotlight 'tag:Migrated' surfaces the whole tree, not
#      just the leaves. Pre-existing directories are left alone.
#
#  Changes vs v1.2:
#    - move_with_verify now captures mv's stderr into the log, so failures
#      record the actual OS error (e.g. "Operation not permitted",
#      "Permission denied") instead of a bare "mv failed".
#    - When mv returns non-zero, the function checks whether the destination
#      actually exists. macOS 'mv' across volumes is internally cp + rm; if
#      the cp phase succeeds but the rm phase trips over signature-protected
#      files or TCC-restricted paths, mv returns non-zero but the destination
#      is intact. Previously these were reported as failures; now they're
#      logged as "copied, source cleanup failed — destination intact" and
#      counted as successes.
#
#  Changes vs v1.1:
#    - Step 3: if a Mac standard library's destination already exists, the
#      script now OFFERS to archive the old one into <folder>/Imported/YYYY/
#      instead of silently skipping. macOS auto-creates many of these dest
#      folders even when empty, and you almost always want your old data.
#    - Step 4: expanded the cert/key search to include PGP keys (.asc .gpg)
#      and other key formats (.ppk .bks .jks .keystore .kdbx). Output
#      folder renamed from 'Imported-Certs' to 'Keys and Certificates'.
#      Relative paths from $SRC_HOME are preserved inside that folder so
#      bundle structures (.tblk etc.) aren't flattened into name collisions.
#    - Step 5: items already queued for archive in step 3 are skipped here
#      (no double-handling). Known-junk filenames ($RECYCLE.BIN, Thumbs.db,
#      desktop.ini, etc.) are routed to <folder>/Imported/Probably Junk/
#      instead of a year folder.
#    - Date-mode selection moved earlier so step 3 archive paths can use it.
#
#  Phase 2 of a hand-rolled macOS migration. Companion to migrate-apps.sh.
#  Walks you through moving everything in your old home folder to a fresh
#  macOS install, in seven steps:
#
#    1. Confirm source and destination home paths.
#    2. Choose mode (dry-run / execute).
#    3. Mac standard libraries — Photos, Music, Mail, Messages, etc.
#       Each is detected by its well-known filename; you say y/n per library.
#    4. Security materials — SSH keys, GPG keys, loose certificate files,
#       and (conditionally) the old login Keychain. The Keychain offer is
#       skipped if you confirm you use iCloud Keychain.
#    5. Loose files in standard folders — Documents, Desktop, Downloads,
#       Pictures, Movies, Music. Files at the top level of each get sorted
#       into "Imported/YYYY/" based on a date type you pick (created or
#       modified). Library files (Photos Library, etc.) are excluded; they
#       were already handled in step 3.
#    6. Other top-level folders in the old home (e.g. ~/GitHub, ~/Projects).
#       Each non-standard folder is presented for include/skip.
#    7. Dotfiles and dotdirs (.zshrc, .config, .npm, etc.). Listed for
#       include/skip. .ssh and .gnupg are handled in step 4 and excluded
#       here.
#
#  Safety
#    - Default mode is DRY-RUN. Nothing is written until you choose execute.
#    - The script builds a complete plan from all your answers, shows a
#      summary, asks one last confirmation, then performs moves.
#    - All mv operations skip destinations that already exist (no clobber).
#    - Time Machine backup before --execute is strongly recommended.
#
#  Usage
#    chmod +x migrate-home.sh
#    ./migrate-home.sh
# ============================================================================

set -uo pipefail

# ============================================================================
#  CONFIGURATION  (edit defaults when sharing the script)
# ============================================================================

DEFAULT_SRC_VOL="/Volumes/Old Data"
DEFAULT_SRC_HOME="$DEFAULT_SRC_VOL/Users/$(whoami)"
DEFAULT_DST_HOME="$HOME"

# Standard top-level folders we know how to handle in step 5 (year-sort).
# Anything in the old home that isn't in this list, isn't "Library", isn't
# "Public", isn't "Applications", and doesn't start with "." is treated as
# a user folder in step 6.
STANDARD_FOLDERS=( "Documents" "Desktop" "Downloads" "Pictures" "Movies" "Music" )

# Mac standard library files. Each entry:
#   relative_path|friendly_name|notes
# relative_path is relative to the source home folder; supports basic globs.
KNOWN_LIBRARIES=(
  "Pictures/Photos Library.photoslibrary|Photos Library|Apple Photos database. Often the largest item in the home. iCloud Photos users can re-download instead."
  "Pictures/Aperture Library.aplibrary|Aperture Library|Legacy Aperture (Apple discontinued 2015)."
  "Pictures/iPhoto Library.photolibrary|iPhoto Library|Legacy iPhoto."
  "Music/Music|Apple Music library folder|Music.app library. Contains your imported tracks and metadata."
  "Music/iTunes|iTunes library|Legacy iTunes (pre-Catalina)."
  "Music/Audio Music Apps|Audio Music Apps|Logic Pro / GarageBand projects, channel strips, sampler instruments. Critical for Logic users."
  "Movies/*.fcpbundle|Final Cut Pro libraries|Each .fcpbundle is a separate FCP library — can be very large."
  "Movies/*.imovielibrary|iMovie libraries|iMovie project libraries."
  "Movies/*.theater|iMovie theater|Shared iMovie projects."
  "Library/Mail|Apple Mail|Mailboxes and accounts. IMAP/iCloud accounts re-sync, so this is mostly only useful for POP3 or local-only mailboxes."
  "Library/Messages|Messages|iMessage / SMS history (chat.db) and attachments. Note: iMessage in iCloud may re-sync."
  "Library/Calendars|Calendar (local)|Local-only calendars. iCloud calendars sync separately."
  "Library/Application Support/AddressBook|Address Book / Contacts (local)|Local-only contacts. iCloud contacts sync separately."
  "Library/Group Containers/group.com.apple.notes|Notes|Apple Notes data. iCloud Notes sync separately."
  "Library/Safari|Safari (history, bookmarks, downloads list)|Local Safari state. iCloud may sync bookmarks separately."
  "Library/Application Support/com.apple.voicememos.macos|Voice Memos|Voice Memos recordings. iCloud may sync."
)

# Extensions to exclude during step 5 (year-sort) — these are libraries
# already handled in step 3 and shouldn't be moved into Imported/.
LIBRARY_EXTENSIONS=( "photoslibrary" "aplibrary" "photolibrary" "musiclibrary" "fcpbundle" "imovielibrary" "theater" )

# File extensions treated as certificate / key material in step 4. Captures
# PGP key material (.asc .gpg), SSH putty-style keys (.ppk), Java keystores
# (.bks .jks .keystore), and KeePass databases (.kdbx) in addition to the
# standard X.509 / PKCS#12 forms.
KEY_EXTENSIONS=( "p12" "pfx" "pem" "crt" "cer" "der" "key" "asc" "gpg" "ppk" "bks" "jks" "keystore" "kdbx" )

# Top-level junk filenames that should be routed to Imported/Probably Junk/
# rather than a year folder. Most of these are Windows-on-Mac artifacts from
# external drives that get mounted on macOS.
JUNK_PATTERNS=( '$RECYCLE.BIN' 'Thumbs.db' 'desktop.ini' '.DS_Store' '.Spotlight-V100' '.fseventsd' '.TemporaryItems' '.Trashes' )

# ============================================================================
#  END CONFIGURATION
# ============================================================================

LOG="$HOME/migration-home-$(date +%Y%m%d-%H%M%S).log"

# Plan: three parallel arrays. Use these instead of a single joined-string
# array because filenames may contain ANY character except '/' and NUL —
# including '|', tabs, etc. — and splitting later would corrupt paths.
declare -a PLAN_SRC=()
declare -a PLAN_DST=()
declare -a PLAN_LABEL=()

# ---- helpers -----------------------------------------------------------------

log()     { printf '%s\n' "$*" | tee -a "$LOG"; }
logonly() { printf '%s\n' "$*" >> "$LOG"; }

banner() {
  log ""
  log "============================================================"
  log "  $*"
  log "============================================================"
}

ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply
    reply="${reply:-$default}"
  else
    read -r -p "$prompt: " reply
  fi
  printf '%s' "$reply"
  logonly "PROMPT: $prompt"
  logonly "ANSWER: $reply"
}

confirm_yn() {
  local prompt="$1" default="${2:-N}" reply
  local hint
  [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$prompt $hint: " reply
  reply="${reply:-$default}"
  logonly "PROMPT: $prompt"
  logonly "ANSWER: $reply"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

plan_add() {
  PLAN_SRC+=("$1")
  PLAN_DST+=("$2")
  PLAN_LABEL+=("$3")
}

# epoch->year, using stat. arg 2: "mtime" or "btime"
year_of() {
  local path="$1" mode="${2:-mtime}" epoch
  if [[ "$mode" == "btime" ]]; then
    epoch=$(stat -f %B "$path" 2>/dev/null)
  else
    epoch=$(stat -f %m "$path" 2>/dev/null)
  fi
  if [[ -z "$epoch" || "$epoch" == "0" ]]; then
    echo "unknown"
  else
    date -r "$epoch" +%Y
  fi
}

# Friendly size (uses du -sh, may be slow for large folders)
size_of() {
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

trap 'echo ""; log "Aborted by user."; exit 130' INT

# ---- intro -------------------------------------------------------------------

cat <<'INTRO'

================================================================
  macOS Home Folder Migration  (Phase 2)
================================================================

Walks you through migrating the contents of your old home folder to
a fresh macOS install. Seven steps:

  1. Confirm source / destination home folders
  2. Choose dry-run or execute mode
  3. Mac standard libraries (Photos, Music, Mail, Messages, etc.)
  4. Security materials (SSH, GPG, certs, optional Keychain)
  5. Loose files in standard folders -> Imported/YYYY/
  6. Other top-level folders in the old home
  7. Dotfiles and dotdirs

Builds a complete plan from your answers, shows a summary, then
asks one final confirmation before any files are moved.

Defaults to DRY-RUN. Nothing is written until you say so.

================================================================
INTRO

# ============================================================================
#  STEP 1 — paths
# ============================================================================

banner "Step 1: Confirm source and destination home folders"
echo ""
echo "Press Enter to accept the [default], or type a replacement path."
echo ""

SRC_HOME="$(ask 'Source home folder' "$DEFAULT_SRC_HOME")"
DST_HOME="$(ask 'Destination home folder' "$DEFAULT_DST_HOME")"
SRC_HOME="${SRC_HOME%/}"
DST_HOME="${DST_HOME%/}"

[[ -d "$SRC_HOME" ]] || { log "ERROR: source home not found: $SRC_HOME"; exit 1; }
[[ -d "$DST_HOME" ]] || { log "ERROR: destination home not found: $DST_HOME"; exit 1; }

log ""
log "Using:"
log "  SRC_HOME = $SRC_HOME"
log "  DST_HOME = $DST_HOME"
log "  log file = $LOG"

# ============================================================================
#  STEP 2 — mode
# ============================================================================

banner "Step 2: Choose mode"
echo ""
mode="$(ask 'Mode (dry-run / execute)' 'dry-run')"
DRY_RUN=true
case "$mode" in execute|EXECUTE) DRY_RUN=false ;; esac

if ! $DRY_RUN; then
  echo ""
  confirm_yn "EXECUTE selected — files will actually be moved. Continue?" "N" || { log "Aborted."; exit 0; }
fi

log ""
log "Mode: $([[ $DRY_RUN == true ]] && echo 'DRY-RUN' || echo 'EXECUTE')"

# ---- Date-mode selection (used by step 3 archive paths and step 5 year-sort)
echo ""
date_mode="mtime"
date_choice="$(ask 'Date mode for Imported/YYYY/ sorting (modified / created)' 'modified')"
case "$date_choice" in
  created|CREATED|btime) date_mode="btime"; log "Date mode: created (btime)" ;;
  *)                     date_mode="mtime"; log "Date mode: modified (mtime)" ;;
esac

# ---- Optional Finder tagging ----
echo ""
echo "Optionally apply a Finder tag to every migrated item, so you can"
echo "spotlight or filter for them later (e.g. tag:Migrated in Finder)."
echo "Leave blank to skip tagging."
TAG_NAME="$(ask 'Finder tag name' 'Migrated')"
TAG_COLOR="4"   # 0=none 1=gray 2=green 3=purple 4=blue 5=yellow 6=red 7=orange
if [[ -n "$TAG_NAME" ]]; then
  log "Tag: items will be tagged \"$TAG_NAME\" (color $TAG_COLOR)."
else
  log "Tag: disabled."
fi

# Compute the archive destination for a library whose canonical destination
# already exists. Routes by source's first path component:
#   - Source in Pictures/Music/Movies/Documents/Desktop/Downloads
#       -> $DST_HOME/<that>/Imported/YYYY/<leaf>
#   - Source in Library/ (or anything else)
#       -> $DST_HOME/Documents/Imported/Old Library Data/YYYY/<leaf>
library_archive_dst() {
  local src="$1"
  local rel="${src#$SRC_HOME/}"
  local first="${rel%%/*}"
  local leaf
  leaf="$(basename "$src")"
  local year
  year=$(year_of "$src" "$date_mode")
  case "$first" in
    Pictures|Music|Movies|Documents|Desktop|Downloads)
      printf '%s\n' "$DST_HOME/$first/Imported/$year/$leaf"
      ;;
    *)
      printf '%s\n' "$DST_HOME/Documents/Imported/Old Library Data/$year/$leaf"
      ;;
  esac
}

# Check whether a given source path is already queued in PLAN_SRC.
is_already_queued() {
  local path="$1"
  for q in "${PLAN_SRC[@]:-}"; do
    [[ "$q" == "$path" ]] && return 0
  done
  return 1
}

# Check whether a top-level item name matches a known-junk pattern.
is_junk() {
  local name="$1"
  for p in "${JUNK_PATTERNS[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

# ============================================================================
#  STEP 3 — Mac standard libraries
# ============================================================================

banner "Step 3: Mac standard libraries"
echo ""
echo "For each library that exists on the source, decide whether to move it."
echo ""

approve_all_libs=false

for entry in "${KNOWN_LIBRARIES[@]}"; do
  IFS='|' read -r rel_path friendly notes <<< "$entry"

  # Resolve globs. Use compgen so we get an array if multiple matches.
  matches=()
  while IFS= read -r m; do
    [[ -n "$m" && -e "$m" ]] && matches+=("$m")
  done < <(compgen -G "$SRC_HOME/$rel_path" 2>/dev/null || true)

  if [[ ${#matches[@]} -eq 0 ]]; then
    continue
  fi

  for src in "${matches[@]}"; do
    leaf="$(basename "$src")"
    rel="${src#$SRC_HOME/}"
    dst_canonical="$DST_HOME/$rel"

    log ""
    log "Found: $friendly"
    log "  source: $src"
    log "  size:   $(size_of "$src")"
    log "  about:  $notes"

    # Two paths: canonical destination free vs. occupied.
    if [[ -e "$dst_canonical" ]]; then
      # macOS commonly auto-creates empty Music/Photos Library/Mail folders
      # on first login. So a pre-existing destination doesn't mean "you
      # already have your data" — it usually means "the OS made an empty
      # placeholder". Offer to archive the old copy into Imported instead
      # of silently skipping.
      dst_archive="$(library_archive_dst "$src")"
      log "  canonical dest already exists at: $dst_canonical"
      log "  (probably an empty placeholder created by macOS)"
      log "  archive option:                    $dst_archive"
      label="Library archive: $friendly"
      prompt_text="Archive this $friendly to its Imported folder?"
      target_dst="$dst_archive"
    else
      log "  dest:   $dst_canonical"
      label="Library: $friendly"
      prompt_text="Migrate this library to its canonical destination?"
      target_dst="$dst_canonical"
    fi

    if $approve_all_libs; then
      log "  ---> queued (approve-all in effect)"
      plan_add "$src" "$target_dst" "$label"
      continue
    fi

    while :; do
      read -r -p "  $prompt_text [y/N/a/q/?]: " ans
      ans="${ans:-N}"
      logonly "PROMPT: $prompt_text ($friendly)"
      logonly "ANSWER: $ans"
      case "$ans" in
        [Yy]*) plan_add "$src" "$target_dst" "$label"; log "  ---> queued"; break ;;
        [Nn]*) log "  ---> skipped"; break ;;
        [Aa]*) approve_all_libs=true; plan_add "$src" "$target_dst" "$label"; log "  ---> approve-all from now on"; break ;;
        [Qq]*) log "  ---> stopping library prompts"; break 2 ;;
        *)
          echo "    y/n = yes/no for this library"
          echo "    a   = yes to all remaining libraries"
          echo "    q   = stop prompting for libraries"
          ;;
      esac
    done
  done
done

# ============================================================================
#  STEP 4 — security (SSH, GPG, certs, optional Keychain)
# ============================================================================

banner "Step 4: Security materials"

# ---- iCloud Keychain question first ----
echo ""
echo "Do you use iCloud Keychain on the new Mac? (Settings > Apple ID >"
echo "iCloud > Passwords & Keychain)"
echo ""
echo "  - YES: most passwords and Safari forms sync automatically. The script"
echo "         will only migrate SSH/GPG/certs from the old home."
echo "  - NO:  the script will additionally offer to copy your old login"
echo "         Keychain database alongside the new one so you can import"
echo "         items from it via Keychain Access."
echo ""
USES_ICLOUD_KC=false
if confirm_yn "Using iCloud Keychain on this Mac?" "Y"; then
  USES_ICLOUD_KC=true
  log "iCloud Keychain: yes — old login.keychain-db will NOT be migrated."
else
  log "iCloud Keychain: no — old login.keychain-db will be offered."
fi

# ---- ~/.ssh ----
src=".ssh"
if [[ -d "$SRC_HOME/$src" ]]; then
  log ""
  log "Found ~/.ssh"
  log "  source: $SRC_HOME/$src"
  log "  size:   $(size_of "$SRC_HOME/$src")"
  if [[ -e "$DST_HOME/$src" ]]; then
    log "  ! destination already exists — listing source contents instead so you can merge manually"
    ls -la "$SRC_HOME/$src" 2>/dev/null | tee -a "$LOG"
  else
    if confirm_yn "Move ~/.ssh to $DST_HOME/.ssh?" "Y"; then
      plan_add "$SRC_HOME/$src" "$DST_HOME/$src" "Security: ~/.ssh"
      log "  ---> queued. After the move, run:"
      log "       chmod 700 ~/.ssh"
      log "       chmod 600 ~/.ssh/id_*"
      log "       ssh-add --apple-use-keychain ~/.ssh/id_*    # adds passphrases to Keychain"
    fi
  fi
fi

# ---- ~/.gnupg ----
src=".gnupg"
if [[ -d "$SRC_HOME/$src" ]]; then
  log ""
  log "Found ~/.gnupg"
  log "  source: $SRC_HOME/$src"
  log "  size:   $(size_of "$SRC_HOME/$src")"
  if [[ -e "$DST_HOME/$src" ]]; then
    log "  ! destination already exists — skipped"
  else
    if confirm_yn "Move ~/.gnupg?" "Y"; then
      plan_add "$SRC_HOME/$src" "$DST_HOME/$src" "Security: ~/.gnupg"
      log "  ---> queued"
    fi
  fi
fi

# ---- Loose key / certificate / PGP files in obvious locations ----
log ""
log "Scanning for keys, certificates, and PGP material in Desktop, Documents, Downloads..."
log "(extensions: ${KEY_EXTENSIONS[*]})"
key_finds=()
for d in "Desktop" "Documents" "Downloads"; do
  [[ -d "$SRC_HOME/$d" ]] || continue
  for ext in "${KEY_EXTENSIONS[@]}"; do
    while IFS= read -r f; do
      [[ -n "$f" ]] && key_finds+=("$f")
    done < <(find "$SRC_HOME/$d" -type f -iname "*.$ext" 2>/dev/null)
  done
done

if [[ ${#key_finds[@]} -gt 0 ]]; then
  log "Found ${#key_finds[@]} key / certificate file(s):"
  for f in "${key_finds[@]}"; do log "  - $f"; done
  echo ""
  log "These will be consolidated under:"
  log "    $DST_HOME/Documents/Keys and Certificates/"
  log "with relative paths from your home folder preserved so identically-"
  log "named files from different folders don't collide and bundle layouts"
  log "(e.g. ultra.tblk/) stay readable."
  if confirm_yn "Move all of these into 'Keys and Certificates'?" "Y"; then
    key_dst_dir="$DST_HOME/Documents/Keys and Certificates"
    for f in "${key_finds[@]}"; do
      rel="${f#$SRC_HOME/}"
      plan_add "$f" "$key_dst_dir/$rel" "Key/Cert: $rel"
    done
    log "  ---> ${#key_finds[@]} key/cert file(s) queued"
  fi
else
  log "  (no key/cert files found)"
fi

# ---- Old login Keychain (only if not using iCloud Keychain) ----
if ! $USES_ICLOUD_KC; then
  src_kc="$SRC_HOME/Library/Keychains/login.keychain-db"
  if [[ -f "$src_kc" ]]; then
    log ""
    log "Old login Keychain found:"
    log "  source: $src_kc"
    log "  size:   $(size_of "$src_kc")"
    log ""
    log "  This file is encrypted with your OLD user password. The safest"
    log "  way to bring its contents over is to place it alongside the new"
    log "  Keychain and import items via Keychain Access."
    log ""
    dst_kc="$DST_HOME/Library/Keychains/old-mac-login.keychain-db"
    if [[ -e "$dst_kc" ]]; then
      log "  ! $dst_kc already exists — skipped"
    else
      if confirm_yn "Place a copy at $dst_kc and print import instructions?" "Y"; then
        plan_add "$src_kc" "$dst_kc" "Keychain: old-mac-login.keychain-db"
        log "  ---> queued. After it's moved:"
        log "       1. Open Keychain Access (/System/Applications/Utilities/Keychain Access.app)"
        log "       2. File > Add Keychain… > select old-mac-login.keychain-db"
        log "       3. Enter your OLD account password to unlock it"
        log "       4. Drag items into 'login' as needed"
      fi
    fi
  fi
fi

# ============================================================================
#  STEP 5 — Loose files in standard folders -> Imported/YYYY/
# ============================================================================

banner "Step 5: Year-sort loose files in standard folders"

echo ""
echo "For each standard folder (Documents, Desktop, Downloads, Pictures,"
echo "Movies, Music), this step groups every top-level item into"
echo "<folder>/Imported/YYYY/<item> based on the date mode you picked"
echo "earlier (modified or created)."
echo ""
echo "Routing rules:"
echo "  - Items already queued for archival in step 3 are skipped here."
echo "  - Known library files (.photoslibrary, .fcpbundle, etc.) are also"
echo "    excluded; those were offered in step 3."
echo "  - Filenames matching known-junk patterns (\$RECYCLE.BIN, Thumbs.db,"
echo "    desktop.ini, etc.) are routed to <folder>/Imported/Probably Junk/"
echo "    instead of a year folder, so you can sweep them in one click."
echo ""
log "(reusing date mode chosen above: $date_mode)"

# Helper: known-library extension check (these were handled in step 3).
is_library_item() {
  local name="$1"
  for ext in "${LIBRARY_EXTENSIONS[@]}"; do
    [[ "$name" == *".$ext" ]] && return 0
  done
  return 1
}

for folder in "${STANDARD_FOLDERS[@]}"; do
  src_folder="$SRC_HOME/$folder"
  dst_folder="$DST_HOME/$folder"
  [[ -d "$src_folder" ]] || continue

  # Enumerate top-level items, excluding dotfiles, known libraries, and
  # anything already queued in an earlier step (e.g. step 3 archives).
  items=()
  while IFS= read -r item; do
    base="$(basename "$item")"
    [[ "$base" == .* ]] && continue
    is_library_item "$base" && continue
    is_already_queued "$item" && continue
    items+=("$item")
  done < <(find "$src_folder" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | sort)

  log ""
  log "Folder: $folder"
  log "  source:        $src_folder"
  log "  items at root: ${#items[@]}"

  if [[ ${#items[@]} -eq 0 ]]; then
    log "  (nothing to sort)"
    continue
  fi

  # Classify and preview: junk vs year buckets.
  junk_count=0
  yrs=()
  routes=()  # "year" or "junk" per item
  for it in "${items[@]}"; do
    base="$(basename "$it")"
    if is_junk "$base"; then
      yrs+=("-")
      routes+=("junk")
      ((junk_count++))
    else
      y=$(year_of "$it" "$date_mode")
      yrs+=("$y")
      routes+=("year")
    fi
  done

  uniq_yrs=$(for r in "${!routes[@]}"; do
    [[ "${routes[$r]}" == "year" ]] && printf '%s\n' "${yrs[$r]}"
  done | sort -u | tr '\n' ' ')
  log "  year span:     ${uniq_yrs:-(none)}"
  log "  junk items:    $junk_count"

  if ! confirm_yn "Sort $folder items into $folder/Imported/?" "N"; then
    log "  ---> skipped"
    continue
  fi

  for i in "${!items[@]}"; do
    it="${items[$i]}"
    leaf="$(basename "$it")"
    if [[ "${routes[$i]}" == "junk" ]]; then
      plan_add "$it" "$dst_folder/Imported/Probably Junk/$leaf" "Probably Junk ($folder): $leaf"
    else
      y="${yrs[$i]}"
      plan_add "$it" "$dst_folder/Imported/$y/$leaf" "Imported/$y ($folder): $leaf"
    fi
  done
  log "  ---> ${#items[@]} item(s) queued for $folder ($junk_count to Probably Junk)"
done

# ============================================================================
#  STEP 6 — Other top-level home folders
# ============================================================================

banner "Step 6: Other top-level folders in the old home"

# Folders that are macOS-managed or already handled.
SKIP_SET=(
  "Documents" "Desktop" "Downloads" "Pictures" "Movies" "Music"
  "Library" "Public" "Applications"
)

other_dirs=()
while IFS= read -r d; do
  base="$(basename "$d")"
  [[ "$base" == .* ]] && continue
  skip=false
  for s in "${SKIP_SET[@]}"; do [[ "$base" == "$s" ]] && skip=true; done
  $skip && continue
  other_dirs+=("$d")
done < <(find "$SRC_HOME" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

if [[ ${#other_dirs[@]} -eq 0 ]]; then
  log ""
  log "(no other top-level folders found)"
else
  log ""
  log "Found ${#other_dirs[@]} non-standard top-level folder(s)."
  approve_all_other=false
  for d in "${other_dirs[@]}"; do
    base="$(basename "$d")"
    dst="$DST_HOME/$base"

    log ""
    log "Folder: ~/$base"
    log "  source: $d"
    log "  size:   $(size_of "$d")"
    if [[ -e "$dst" ]]; then
      log "  ! destination already exists — skipped"
      continue
    fi

    if $approve_all_other; then
      plan_add "$d" "$dst" "Folder: ~/$base"
      log "  ---> queued (approve-all)"
      continue
    fi

    while :; do
      read -r -p "  Migrate ~/$base? [y/N/a/q/?]: " ans
      ans="${ans:-N}"
      logonly "PROMPT: Migrate ~/$base?"
      logonly "ANSWER: $ans"
      case "$ans" in
        [Yy]*) plan_add "$d" "$dst" "Folder: ~/$base"; log "  ---> queued"; break ;;
        [Nn]*) log "  ---> skipped"; break ;;
        [Aa]*) approve_all_other=true; plan_add "$d" "$dst" "Folder: ~/$base"; log "  ---> approve-all"; break ;;
        [Qq]*) log "  ---> stopping folder prompts"; break 2 ;;
        *)
          echo "    y/n = yes/no"
          echo "    a   = yes to all remaining folders"
          echo "    q   = stop prompting"
          ;;
      esac
    done
  done
fi

# ============================================================================
#  STEP 7 — Dotfiles and dotdirs
# ============================================================================

banner "Step 7: Dotfiles and dotdirs"

# Already handled or risky to blindly move.
DOT_SKIP=(
  ".ssh" ".gnupg" ".Trash" ".CFUserTextEncoding" ".DS_Store" ".localized"
  ".bash_sessions" ".lesshst" ".viminfo"
)

dot_items=()
while IFS= read -r d; do
  base="$(basename "$d")"
  skip=false
  for s in "${DOT_SKIP[@]}"; do [[ "$base" == "$s" ]] && skip=true; done
  $skip && continue
  dot_items+=("$d")
done < <(find "$SRC_HOME" -mindepth 1 -maxdepth 1 -name '.*' 2>/dev/null | sort)

if [[ ${#dot_items[@]} -eq 0 ]]; then
  log ""
  log "(no dotfiles or dotdirs to consider)"
else
  log ""
  log "Found ${#dot_items[@]} dotfile(s) / dotdir(s)."
  log "Common picks: .zshrc, .gitconfig, .tmux.conf, .config (dev tools),"
  log "              .npmrc, .gemrc, .vscode, .cursor, .docker."
  log "Skip: anything that conflicts with the new system's own setup."

  approve_all_dot=false
  for d in "${dot_items[@]}"; do
    base="$(basename "$d")"
    dst="$DST_HOME/$base"

    log ""
    if [[ -f "$d" ]]; then
      log "Dotfile: ~/$base ($(size_of "$d"))"
    else
      log "Dotdir:  ~/$base ($(size_of "$d"))"
    fi
    log "  source: $d"
    if [[ -e "$dst" ]]; then
      log "  ! $dst already exists — skipped"
      continue
    fi

    if $approve_all_dot; then
      plan_add "$d" "$dst" "Dot: ~/$base"
      log "  ---> queued (approve-all)"
      continue
    fi

    while :; do
      read -r -p "  Migrate ~/$base? [y/N/a/q/?]: " ans
      ans="${ans:-N}"
      logonly "PROMPT: Migrate ~/$base?"
      logonly "ANSWER: $ans"
      case "$ans" in
        [Yy]*) plan_add "$d" "$dst" "Dot: ~/$base"; log "  ---> queued"; break ;;
        [Nn]*) log "  ---> skipped"; break ;;
        [Aa]*) approve_all_dot=true; plan_add "$d" "$dst" "Dot: ~/$base"; log "  ---> approve-all"; break ;;
        [Qq]*) log "  ---> stopping dot prompts"; break 2 ;;
        *)
          echo "    y/n = yes/no"
          echo "    a   = yes to all remaining"
          echo "    q   = stop prompting"
          ;;
      esac
    done
  done
fi

# ============================================================================
#  STEP 8 — summary + final confirmation
# ============================================================================

banner "Step 8: Migration plan summary"

if [[ ${#PLAN_SRC[@]} -eq 0 ]]; then
  log ""
  log "Nothing queued. Exiting."
  exit 0
fi

log ""
log "Queued operations: ${#PLAN_SRC[@]}"
log ""
for i in "${!PLAN_SRC[@]}"; do
  log "  [${PLAN_LABEL[$i]}]"
  log "    ${PLAN_SRC[$i]}"
  log "      -> ${PLAN_DST[$i]}"
done

log ""
log "Mode: $([[ $DRY_RUN == true ]] && echo 'DRY-RUN (no changes will be made)' || echo 'EXECUTE (files will be moved)')"

echo ""
if $DRY_RUN; then
  # Dry-run: this prompt is purely informational. Y prints the simulated
  # 'mv' commands; N exits. Disk is not touched either way.
  confirm_yn "Print simulated mv commands? (No effect on disk either way)" "Y" || { log "Aborted."; exit 0; }
else
  confirm_yn "FINAL CONFIRMATION — perform all moves above" "N" || { log "Aborted at final confirmation."; exit 0; }
fi

# ============================================================================
#  STEP 9 — execute
# ============================================================================

banner "Step 9: Performing moves"

# Apply a Finder tag to a path. macOS tags are stored as a binary plist in
# the com.apple.metadata:_kMDItemUserTags xattr. The plist is an array of
# strings, each formatted as "TagName\n<color>" with a literal newline.
# Tag-write failures are non-fatal — the move already succeeded.
apply_finder_tag() {
  local path="$1"
  [[ -z "$TAG_NAME" ]] && return 0
  [[ ! -e "$path" ]] && return 0
  $DRY_RUN && return 0

  local tmp hex
  tmp=$(mktemp -t migrator-tag.XXXXXX) || return 0
  cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
<string>${TAG_NAME}
${TAG_COLOR}</string>
</array>
</plist>
EOF
  plutil -convert binary1 "$tmp" 2>/dev/null
  hex=$(xxd -p "$tmp" 2>/dev/null | tr -d '\n')
  rm -f "$tmp"
  [[ -z "$hex" ]] && return 0
  xattr -wx com.apple.metadata:_kMDItemUserTags "$hex" "$path" 2>/dev/null || true
}

move_with_verify() {
  local src="$1" dst="$2" label="${3:-move}"
  local mv_err

  if [[ ! -e "$src" ]]; then
    log "  SKIP ($label) — source missing: $src"; return 1
  fi
  if [[ -e "$dst" ]]; then
    log "  SKIP ($label) — destination already exists: $dst"; return 1
  fi

  # Make sure the destination directory exists (we may create intermediate
  # dirs like Imported/YYYY/, Keys and Certificates/, Library/Keychains/).
  # When tagging is on, also tag every intermediate dir THIS script creates,
  # so Finder spotlight surfaces the whole Imported tree under tag:Migrated
  # — not just the leaves. Pre-existing dirs are left alone.
  local dst_dir
  dst_dir="$(dirname "$dst")"
  local newly_created=()
  if [[ ! -d "$dst_dir" ]]; then
    # Walk up from dst_dir, collecting each level that doesn't exist yet,
    # stopping at DST_HOME or filesystem root.
    local p="$dst_dir"
    while [[ ! -d "$p" && "$p" != "$DST_HOME" && "$p" != "/" && "$p" != "." ]]; do
      # Prepend so the list goes parent-to-child once we exit
      newly_created=("$p" "${newly_created[@]:-}")
      p="$(dirname "$p")"
    done

    if $DRY_RUN; then
      log "  [DRY-RUN] mkdir -p \"$dst_dir\""
    else
      mkdir -p "$dst_dir" || { log "  ✗ mkdir failed: $dst_dir"; return 1; }
      # Tag each intermediate dir we just brought into existence
      for d in "${newly_created[@]:-}"; do
        [[ -n "$d" ]] && apply_finder_tag "$d"
      done
    fi
  fi

  if $DRY_RUN; then
    log "  [DRY-RUN] mv \"$src\" \"$dst\""
    return 0
  fi

  # macOS 'mv' for cross-volume moves is internally cp + rm. Signed bundles
  # and protected Library subfolders may resist the rm phase even when the
  # cp phase succeeds. Distinguish "real failure" (destination missing) from
  # "moved but couldn't clean source" (destination intact, source detritus).
  if mv_err=$(mv "$src" "$dst" 2>&1); then
    if [[ -e "$dst" ]]; then
      apply_finder_tag "$dst"
      log "  ✓ moved ($label): $dst"
      return 0
    fi
    log "  ✗ mv returned 0 but destination missing: $dst"; return 1
  fi

  if [[ -e "$dst" ]]; then
    apply_finder_tag "$dst"
    log "  ⚠ copied ($label), but source cleanup failed: $dst"
    log "    destination is intact — fully migrated"
    log "    source detritus left at: $src"
    log "    (safe to ignore; cleans up when you reformat, or: sudo rm -rf \"$src\")"
    return 0
  fi

  log "  ✗ mv failed: $src -> $dst"
  [[ -n "$mv_err" ]] && log "    reason: $mv_err"
  return 1
}

ok=0; failed=0
for i in "${!PLAN_SRC[@]}"; do
  src="${PLAN_SRC[$i]}"
  dst="${PLAN_DST[$i]}"
  label="${PLAN_LABEL[$i]}"
  log ""
  log "[$label]"
  if move_with_verify "$src" "$dst" "$label"; then
    ((ok++))
  else
    ((failed++))
  fi
done

banner "Done"
log "Mode was: $([[ $DRY_RUN == true ]] && echo 'DRY-RUN' || echo 'EXECUTE')"
log "Operations attempted: ${#PLAN_SRC[@]}   ok: $ok   skipped/failed: $failed"
log "Full log: $LOG"

if ! $DRY_RUN && [[ -d "$DST_HOME/.ssh" ]]; then
  log ""
  log "Post-move SSH housekeeping (run these if you migrated ~/.ssh):"
  log "  chmod 700 ~/.ssh"
  log "  chmod 600 ~/.ssh/id_* 2>/dev/null"
  log "  ssh-add --apple-use-keychain ~/.ssh/id_* 2>/dev/null"
fi
