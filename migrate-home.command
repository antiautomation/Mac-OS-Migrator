#!/bin/bash
# ----------------------------------------------------------------------------
#  migrate-home.command
#
#  Double-clickable launcher for migrate-home.sh. Opens Terminal automatically,
#  changes to this file's directory, makes the .sh script executable if it
#  isn't already, runs it, and keeps the window open at the end so you can
#  read the result.
#
#  If you'd rather drive the script from your own terminal, run migrate-home.sh
#  directly. This wrapper is just a friendlier on-ramp.
# ----------------------------------------------------------------------------

set -u

cd "$(dirname "$0")" || exit 1

clear
cat <<'BANNER'
================================================================
  Mac OS Migrator — Phase 2: Home Folder
================================================================

This walks you through migrating the contents of your old home
folder — Mac standard libraries (Photos, Music, Mail, etc.),
SSH/GPG/certs, year-sorted loose files, other top-level folders,
and dotfiles.

The script defaults to DRY-RUN. Nothing is written until you
explicitly choose 'execute' at the mode prompt.

================================================================

BANNER

SCRIPT="./migrate-home.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: $SCRIPT not found in $(pwd)."
  echo "       Make sure this .command file is in the same folder as the .sh scripts."
  echo ""
  read -r -p "Press Enter to close this window... " _
  exit 1
fi

chmod +x "$SCRIPT" 2>/dev/null

echo "Running: $SCRIPT"
echo ""
"$SCRIPT"
status=$?

echo ""
echo "================================================================"
if [[ $status -eq 0 ]]; then
  echo "  Done. (exit code 0)"
else
  echo "  Exited with code $status."
fi
echo "================================================================"
echo ""
read -r -p "Press Enter to close this window... " _
