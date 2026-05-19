#!/bin/bash
# ----------------------------------------------------------------------------
#  migrate-apps.sh  (v4.2 — broken-bundle hardening)
#
#  Changes vs v4.1:
#    - get_bundle_id and get_display_name now verify that Info.plist exists
#      before invoking PlistBuddy. Some broken .app bundles ship without a
#      readable Info.plist, in which case PlistBuddy writes a "File Doesn't
#      Exist, Will Create: ..." message to STDOUT (not stderr — long-standing
#      PlistBuddy quirk). Without the guard, that error string was captured
#      as the app's bundle ID and display name, polluting the probe output
#      and the final summary.
#
#  Hand-pick applications and their user data to migrate from a previous
#  macOS install (mounted as a "data" volume, typically /Volumes/Old Data)
#  to a fresh macOS install. The script:
#
#    1) confirms source and destination paths with you interactively,
#    2) confirms dry-run vs real execution,
#    3) probes each candidate .app — reading bundle ID from Info.plist
#       and finding matching Application Support, Preferences, Containers,
#       and Group Containers on the source volume,
#    4) auto-skips any app that is already installed at the destination
#       (in /Applications, /System/Applications, or
#        /System/Applications/Utilities),
#    5) asks you per-app, by friendly display name, whether to migrate it,
#    6) shows a final summary and asks for one last confirmation
#       before performing any mv operations.
#
#  Use this on a Mac you've just wiped, with the previous "Data" volume
#  attached. Always have a Time Machine backup before running with --execute.
#
#  Customizing for your install: edit the APPS array below — the .app
#  filenames you actually want this script to consider. If you leave APPS
#  empty, the script will scan the source Applications folder and ask about
#  every .app it finds.
# ----------------------------------------------------------------------------

set -uo pipefail

# ============================================================================
#  CONFIGURATION — edit this block when sharing the script
# ============================================================================

# Default paths. You'll be asked to confirm or override these at runtime.
DEFAULT_SRC_VOL="/Volumes/Old Data"
DEFAULT_SRC_APPS="$DEFAULT_SRC_VOL/Applications"
DEFAULT_SRC_LIB="$DEFAULT_SRC_VOL/Users/$(whoami)/Library"
DEFAULT_DST_APPS="/Applications"
DEFAULT_DST_LIB="$HOME/Library"

# Apps to consider. Two modes:
#
#   AUTO-DISCOVER (default): leave APPS=() empty. The script scans the
#   source Applications folder and prompts about every .app it finds.
#   Per-app prompt defaults to "no" — you press 'y' to include.
#
#   CURATED: list .app filenames inside the array below — only those will
#   be considered. Per-app prompt defaults to "yes" — press 'n' to skip.
#   Example:
#     APPS=( "Dia.app" "Spotify.app" "WireGuard.app" )
APPS=()

# ============================================================================
#  END CONFIGURATION
# ============================================================================

LOG="$HOME/migration-$(date +%Y%m%d-%H%M%S).log"

# ---- helpers -----------------------------------------------------------------

log()    { printf '%s\n' "$*" | tee -a "$LOG"; }
logonly(){ printf '%s\n' "$*" >> "$LOG"; }

banner() {
  log ""
  log "============================================================"
  log "  $*"
  log "============================================================"
}

ask() {
  # ask "Prompt: " "default value"   -> echoes the entered (or default) value
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " reply
    reply="${reply:-$default}"
  else
    read -r -p "$prompt: " reply
  fi
  printf '%s' "$reply"
  # Log the Q&A for the record
  logonly "PROMPT: $prompt"
  logonly "ANSWER: $reply"
}

confirm_yn() {
  # confirm_yn "Prompt" "Y" -> returns 0 on yes, 1 on no
  local prompt="$1" default="${2:-N}" reply
  read -r -p "$prompt [${default}/$( [[ $default == Y ]] && echo n || echo y )]: " reply
  reply="${reply:-$default}"
  logonly "PROMPT: $prompt"
  logonly "ANSWER: $reply"
  case "$reply" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

trap 'echo ""; log "Aborted by user."; exit 130' INT

# ---- introduction -----------------------------------------------------------

cat <<'INTRO'

================================================================
  macOS App + User Data Migration (v4)
================================================================

This script moves selected applications and their user data from a
source volume to a fresh macOS install, with interactive confirmation
at every step.

For each app you approve, the following are moved (only if present
on the source, only if not already present at the destination):

  - The .app bundle              ->  destination Applications folder
  - Application Support/<name>   ->  destination ~/Library/...
  - Preferences/<bundle-id>.plist
  - Containers/<bundle-id>       (sandboxed / App Store apps)
  - Group Containers/<group>     (sandboxed apps, matched by bundle ID)

Defaults to DRY-RUN. Nothing is written until you say so.

================================================================

INTRO

# ---- step 1: confirm paths --------------------------------------------------

banner "Step 1: Confirm source and destination paths"
echo ""
echo "Press Enter to accept the [default], or type a replacement path."
echo ""

SRC_APPS="$(ask 'Source Applications folder' "$DEFAULT_SRC_APPS")"
SRC_LIB="$(ask  'Source Library folder'      "$DEFAULT_SRC_LIB")"
DST_APPS="$(ask 'Destination Applications folder' "$DEFAULT_DST_APPS")"
DST_LIB="$(ask  'Destination Library folder'      "$DEFAULT_DST_LIB")"

# Strip any trailing slashes for consistency
SRC_APPS="${SRC_APPS%/}"; SRC_LIB="${SRC_LIB%/}"
DST_APPS="${DST_APPS%/}"; DST_LIB="${DST_LIB%/}"

# Validate
[[ -d "$SRC_APPS" ]] || { log "ERROR: source apps folder not found: $SRC_APPS"; exit 1; }
[[ -d "$SRC_LIB"  ]] || { log "ERROR: source library folder not found: $SRC_LIB";  exit 1; }
[[ -d "$DST_APPS" ]] || { log "ERROR: destination apps folder not found: $DST_APPS"; exit 1; }
[[ -d "$DST_LIB"  ]] || { log "ERROR: destination library folder not found: $DST_LIB"; exit 1; }

# We also check /System/Applications[/Utilities] for the destination check,
# regardless of what the user chose for DST_APPS, because Apple-bundled apps
# land there and should still cause an auto-skip.
DST_SYS_APPS="/System/Applications"
DST_SYS_APPS_UTIL="/System/Applications/Utilities"

log ""
log "Using paths:"
log "  SRC_APPS = $SRC_APPS"
log "  SRC_LIB  = $SRC_LIB"
log "  DST_APPS = $DST_APPS"
log "  DST_LIB  = $DST_LIB"
log "  log file = $LOG"

# ---- step 2: confirm mode ---------------------------------------------------

banner "Step 2: Choose mode"
echo ""
echo "  dry-run  - probe and prompt, but write nothing (recommended first run)"
echo "  execute  - actually move files"
echo ""

mode="$(ask 'Mode (dry-run / execute)' 'dry-run')"
DRY_RUN=true
case "$mode" in
  execute|EXECUTE) DRY_RUN=false ;;
  *)               DRY_RUN=true  ;;
esac

if ! $DRY_RUN; then
  echo ""
  if ! confirm_yn "EXECUTE selected — files will be moved. Continue?" "N"; then
    log "Aborted at execute confirmation."
    exit 0
  fi
fi

log ""
log "Mode: $([[ $DRY_RUN == true ]] && echo 'DRY-RUN' || echo 'EXECUTE')"

# ---- step 3: build the app list --------------------------------------------

auto_discovered=false
if [[ ${#APPS[@]} -eq 0 ]]; then
  auto_discovered=true
  log ""
  log "AUTO-DISCOVER mode — scanning $SRC_APPS for .app bundles..."
  while IFS= read -r line; do APPS+=("$line"); done < <(
    find "$SRC_APPS" -maxdepth 1 -name '*.app' -print 2>/dev/null \
      | sed "s#^$SRC_APPS/##" \
      | sort
  )
  log "Found ${#APPS[@]} app(s). Per-app prompts default to NO; press 'y' to include."
else
  log ""
  log "CURATED mode — using the ${#APPS[@]} app(s) listed in the script."
  log "Per-app prompts default to YES; press 'n' to skip individual apps."
fi

# Default answer when the user just hits Enter on the per-app prompt.
if $auto_discovered; then
  PROMPT_DEFAULT="N"
  PROMPT_LABEL="[y/N/a/q/?]"
else
  PROMPT_DEFAULT="Y"
  PROMPT_LABEL="[Y/n/a/q/?]"
fi

# ---- probe helpers ----------------------------------------------------------

get_bundle_id() {
  local plist="$1/Contents/Info.plist"
  [[ -f "$plist" ]] || return 1
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null
}

get_display_name() {
  local plist="$1/Contents/Info.plist"
  [[ -f "$plist" ]] || return 1
  /usr/libexec/PlistBuddy -c "Print :CFBundleName" "$plist" 2>/dev/null
}

find_destination_match() {
  local app_name="$1"
  for base in "$DST_APPS" "$DST_SYS_APPS" "$DST_SYS_APPS_UTIL"; do
    [[ -d "$base/$app_name" ]] && { printf '%s\n' "$base/$app_name"; return 0; }
  done
  return 1
}

find_app_support_candidates() {
  local app_basename="$1" display_name="$2" bundle_id="$3"
  local tried=() p seen
  for candidate in "$app_basename" "$display_name" "$bundle_id"; do
    [[ -z "$candidate" ]] && continue
    p="$SRC_LIB/Application Support/$candidate"
    seen=false
    for t in "${tried[@]:-}"; do [[ "$t" == "$p" ]] && seen=true; done
    $seen && continue
    tried+=("$p")
    [[ -d "$p" ]] && printf '%s\n' "$p"
  done
}

find_prefs_plist() {
  local bundle_id="$1"
  [[ -z "$bundle_id" ]] && return 0
  local p="$SRC_LIB/Preferences/$bundle_id.plist"
  [[ -f "$p" ]] && printf '%s\n' "$p"
}

find_container_path() {
  local bundle_id="$1"
  [[ -z "$bundle_id" ]] && return 0
  local p="$SRC_LIB/Containers/$bundle_id"
  [[ -d "$p" ]] && printf '%s\n' "$p"
}

# Group Containers are folders named "<TeamID>.<group-id>". We match by
# substring of the bundle ID (full, trailing-2, leading-2; each >= 10 chars
# to keep false positives out). Apple-system groups skipped.
find_group_container_paths() {
  local bundle_id="$1"
  [[ -z "$bundle_id" ]] && return 0
  local gc_root="$SRC_LIB/Group Containers"
  [[ -d "$gc_root" ]] || return 0

  local lead2 trail2
  lead2=$(printf '%s' "$bundle_id" | awk -F. '{ if (NF>=2) print $1"."$2 }')
  trail2=$(printf '%s' "$bundle_id" | awk -F. '{ if (NF>=2) print $(NF-1)"."$NF }')

  find "$gc_root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    local name
    name="$(basename "$dir")"
    case "$name" in
      iCloud.*|group.com.apple.*|com.apple.*) continue ;;
    esac
    if   [[ ${#bundle_id} -ge 10 && "$name" == *"$bundle_id"* ]]; then printf '%s\n' "$dir"
    elif [[ -n "$trail2" && ${#trail2} -ge 10 && "$name" == *"$trail2"* ]]; then printf '%s\n' "$dir"
    elif [[ -n "$lead2"  && ${#lead2}  -ge 10 && "$name" == *"$lead2"*  ]]; then printf '%s\n' "$dir"
    fi
  done | sort -u
}

# ---- step 4: probe + per-app prompt ----------------------------------------

banner "Step 3: Probe each app and confirm migration"

# Per-app parallel arrays. ${APP_DECISION[$i]} is one of:
#   yes     - user approved
#   no      - user declined
#   skip    - already installed at destination, auto-skipped
#   missing - source app not found
declare -a APP_DECISION=()
declare -a APP_BUNDLE=()
declare -a APP_DISPLAY=()
declare -a APP_ALREADY=()
declare -a APP_AS_PATHS=()
declare -a APP_PREFS=()
declare -a APP_CONTAINER=()
declare -a APP_GROUPS=()

approve_all=false
quit_loop=false
total=${#APPS[@]}

for i in "${!APPS[@]}"; do
  app_name="${APPS[$i]}"
  src="$SRC_APPS/$app_name"
  idx_str="[$((i+1))/$total]"

  log ""
  log "$idx_str  $app_name"

  if [[ ! -d "$src" ]]; then
    log "  (not present on source — skipping)"
    APP_DECISION+=("missing")
    APP_BUNDLE+=(""); APP_DISPLAY+=(""); APP_ALREADY+=("")
    APP_AS_PATHS+=(""); APP_PREFS+=(""); APP_CONTAINER+=(""); APP_GROUPS+=("")
    continue
  fi

  bid="$(get_bundle_id "$src")"
  disp="$(get_display_name "$src")"
  [[ -z "$disp" ]] && disp="${app_name%.app}"
  basename_no_ext="${app_name%.app}"

  already="$(find_destination_match "$app_name" || true)"

  log "  display name: $disp"
  log "  bundle id:    ${bid:-<unreadable>}"

  if [[ -n "$already" ]]; then
    log "  status: ALREADY INSTALLED at $already"
    log "  ---> auto-skipping (no prompt)"
    APP_DECISION+=("skip")
    APP_BUNDLE+=("$bid"); APP_DISPLAY+=("$disp"); APP_ALREADY+=("$already")
    APP_AS_PATHS+=(""); APP_PREFS+=(""); APP_CONTAINER+=(""); APP_GROUPS+=("")
    continue
  fi

  # Probe user data for the prompt
  as_paths="$(find_app_support_candidates "$basename_no_ext" "$disp" "$bid")"
  prefs="$(find_prefs_plist "$bid")"
  container="$(find_container_path "$bid")"
  groups="$(find_group_container_paths "$bid")"

  log "  Application Support: $([[ -n "$as_paths" ]] && echo present || echo "(none)")"
  if [[ -n "$as_paths" ]]; then
    while IFS= read -r p; do log "                       - $p"; done <<< "$as_paths"
  fi
  log "  Preferences plist:   $([[ -n "$prefs" ]] && basename "$prefs" || echo "(none)")"
  log "  Container:           $([[ -n "$container" ]] && echo present || echo "(none)")"
  log "  Group Containers:    $([[ -n "$groups" ]] && echo present || echo "(none)")"
  if [[ -n "$groups" ]]; then
    while IFS= read -r g; do log "                       - $g"; done <<< "$groups"
  fi

  # Per-app prompt unless "approve all" or "quit" was chosen earlier
  if $quit_loop; then
    APP_DECISION+=("no")
    APP_BUNDLE+=("$bid"); APP_DISPLAY+=("$disp"); APP_ALREADY+=("")
    APP_AS_PATHS+=("$as_paths"); APP_PREFS+=("$prefs")
    APP_CONTAINER+=("$container"); APP_GROUPS+=("$groups")
    continue
  fi

  if $approve_all; then
    log "  ---> migrating (approve-all in effect)"
    APP_DECISION+=("yes")
    APP_BUNDLE+=("$bid"); APP_DISPLAY+=("$disp"); APP_ALREADY+=("")
    APP_AS_PATHS+=("$as_paths"); APP_PREFS+=("$prefs")
    APP_CONTAINER+=("$container"); APP_GROUPS+=("$groups")
    continue
  fi

  while :; do
    read -r -p "  Migrate $disp? $PROMPT_LABEL: " ans
    ans="${ans:-$PROMPT_DEFAULT}"
    logonly "PROMPT: Migrate $disp?"
    logonly "ANSWER: $ans"
    case "$ans" in
      [Yy]*) APP_DECISION+=("yes"); log "  ---> will migrate"; break ;;
      [Nn]*) APP_DECISION+=("no");  log "  ---> will skip";    break ;;
      [Aa]*) approve_all=true; APP_DECISION+=("yes"); log "  ---> approve-all from now on"; break ;;
      [Qq]*) quit_loop=true;   APP_DECISION+=("no");  log "  ---> stopping prompts, remaining apps will be skipped"; break ;;
      *)
        echo "    y = yes, migrate this app"
        echo "    n = no, skip this app"
        echo "    a = yes to all remaining (use with care in auto-discover mode)"
        echo "    q = stop prompting; skip remaining apps"
        echo "    (default on Enter: $PROMPT_DEFAULT)"
        ;;
    esac
  done

  APP_BUNDLE+=("$bid"); APP_DISPLAY+=("$disp"); APP_ALREADY+=("")
  APP_AS_PATHS+=("$as_paths"); APP_PREFS+=("$prefs")
  APP_CONTAINER+=("$container"); APP_GROUPS+=("$groups")
done

# ---- step 5: summary --------------------------------------------------------

banner "Step 4: Migration plan summary"

to_migrate=(); to_skip_installed=(); to_skip_declined=(); to_skip_missing=()
for i in "${!APPS[@]}"; do
  case "${APP_DECISION[$i]}" in
    yes)     to_migrate+=("${APP_DISPLAY[$i]:-${APPS[$i]}}") ;;
    skip)    to_skip_installed+=("${APP_DISPLAY[$i]:-${APPS[$i]}}") ;;
    no)      to_skip_declined+=("${APP_DISPLAY[$i]:-${APPS[$i]}}") ;;
    missing) to_skip_missing+=("${APPS[$i]}") ;;
  esac
done

log ""
log "Will migrate (${#to_migrate[@]}):"
for n in "${to_migrate[@]:-}"; do [[ -n "$n" ]] && log "  + $n"; done

log ""
log "Auto-skipped, already installed (${#to_skip_installed[@]}):"
for n in "${to_skip_installed[@]:-}"; do [[ -n "$n" ]] && log "  = $n"; done

log ""
log "Skipped by your choice (${#to_skip_declined[@]}):"
for n in "${to_skip_declined[@]:-}"; do [[ -n "$n" ]] && log "  - $n"; done

if [[ ${#to_skip_missing[@]} -gt 0 ]]; then
  log ""
  log "Not present on source (${#to_skip_missing[@]}):"
  for n in "${to_skip_missing[@]:-}"; do [[ -n "$n" ]] && log "  ? $n"; done
fi

log ""
log "Mode: $([[ $DRY_RUN == true ]] && echo 'DRY-RUN (no changes will be made)' || echo 'EXECUTE (files will be moved)')"

if [[ ${#to_migrate[@]} -eq 0 ]]; then
  log ""
  log "Nothing to migrate. Exiting."
  exit 0
fi

echo ""
if $DRY_RUN; then
  if ! confirm_yn "Show the simulated moves for the approved apps?" "Y"; then
    log "Aborted before showing simulated moves."
    exit 0
  fi
else
  if ! confirm_yn "FINAL CONFIRMATION — perform the moves above" "N"; then
    log "Aborted at final confirmation."
    exit 0
  fi
fi

# ---- step 6: perform moves --------------------------------------------------

move_with_verify() {
  local src="$1" dst="$2" label="${3:-move}"

  if [[ ! -e "$src" ]]; then
    log "    SKIP ($label) — source missing: $src"; return 1
  fi
  if [[ -e "$dst" ]]; then
    log "    SKIP ($label) — destination already exists: $dst"; return 1
  fi
  if $DRY_RUN; then
    log "    [DRY-RUN] mv \"$src\" \"$dst\""; return 0
  fi
  if mv "$src" "$dst"; then
    if [[ -e "$dst" ]]; then
      log "    ✓ moved ($label): $dst"; return 0
    fi
    log "    ✗ mv returned 0 but destination missing: $dst"; return 1
  fi
  log "    ✗ mv failed: $src -> $dst"; return 1
}

banner "Step 5: Performing moves"

for i in "${!APPS[@]}"; do
  [[ "${APP_DECISION[$i]}" == "yes" ]] || continue

  app_name="${APPS[$i]}"
  src="$SRC_APPS/$app_name"
  bid="${APP_BUNDLE[$i]}"
  disp="${APP_DISPLAY[$i]:-${app_name%.app}}"

  log ""
  log "App: $disp ($app_name)"

  # 1) the .app bundle
  move_with_verify "$src" "$DST_APPS/$app_name" "app bundle"

  # 2) Application Support
  as_paths="${APP_AS_PATHS[$i]}"
  if [[ -n "$as_paths" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      leaf="$(basename "$p")"
      move_with_verify "$p" "$DST_LIB/Application Support/$leaf" "Application Support"
    done <<< "$as_paths"
  fi

  # 3) Preferences plist
  prefs="${APP_PREFS[$i]}"
  if [[ -n "$prefs" ]]; then
    leaf="$(basename "$prefs")"
    move_with_verify "$prefs" "$DST_LIB/Preferences/$leaf" "Preferences plist"
  fi

  # 4) Container
  container="${APP_CONTAINER[$i]}"
  if [[ -n "$container" ]]; then
    leaf="$(basename "$container")"
    move_with_verify "$container" "$DST_LIB/Containers/$leaf" "Container"
  fi

  # 5) Group Containers
  groups="${APP_GROUPS[$i]}"
  if [[ -n "$groups" ]]; then
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      leaf="$(basename "$g")"
      move_with_verify "$g" "$DST_LIB/Group Containers/$leaf" "Group Container"
    done <<< "$groups"
  fi
done

banner "Done"
log "Mode was: $([[ $DRY_RUN == true ]] && echo 'DRY-RUN — re-run and choose execute to apply' || echo 'EXECUTE — changes were written')"
log "Full log: $LOG"
