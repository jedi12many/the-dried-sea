#!/usr/bin/env bash
# Ops commands for the shared Dried Sea server. Run from anywhere:
#   bash tools/server-cmd.sh status            # service + world day + recent joins
#   bash tools/server-cmd.sh logs [N]          # last N journal lines (default 30)
#   bash tools/server-cmd.sh reset             # STOP -> backup world save -> START fresh
#   bash tools/server-cmd.sh backups           # list world backups on the VM
#   bash tools/server-cmd.sh restore <file>    # STOP -> restore a backup -> START
#
# Why ssh and not an in-game command: player identity is a self-declared
# username (--name), so any in-game /reset would be spoofable by anyone who
# can reach udp/7777. GCP auth is the admin gate.
set -euo pipefail
VM="dried-sea-server"
ZONE="us-east1-b"
PROJECT="mycon-sandbox"
SAVE_DIR="/opt/dried-sea/game/godot/app_userdata/The Dried Sea"
SAVE="$SAVE_DIR/dried-sea-save.json"
BACKUP_DIR="/opt/dried-sea/backups"

run() { gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT" --quiet --command="$1"; }

case "${1:-status}" in
  status)
    run "systemctl is-active dried-sea; sudo journalctl -u dried-sea -n 200 --no-pager | grep -E 'DRIED SEA server|joined:' | tail -8"
    ;;
  logs)
    run "sudo journalctl -u dried-sea -n ${2:-30} --no-pager"
    ;;
  reset)
    STAMP=$(date +%Y%m%d-%H%M%S)
    echo "== stopping server, backing up world to $BACKUP_DIR/world-$STAMP.json, starting fresh =="
    run "sudo systemctl stop dried-sea &&
         sudo mkdir -p '$BACKUP_DIR' &&
         if [ -f '$SAVE' ]; then sudo mv '$SAVE' '$BACKUP_DIR/world-$STAMP.json'; echo 'backed up.'; else echo 'no save present.'; fi &&
         sudo systemctl start dried-sea &&
         sleep 3 && sudo journalctl -u dried-sea -n 2 --no-pager"
    echo "== fresh world. restore with: bash tools/server-cmd.sh restore world-$STAMP.json =="
    ;;
  backups)
    run "ls -lh '$BACKUP_DIR' 2>/dev/null || echo 'no backups yet'"
    ;;
  restore)
    [ -z "${2:-}" ] && { echo "usage: server-cmd.sh restore <backup-file-name>"; exit 1; }
    run "sudo systemctl stop dried-sea &&
         sudo cp '$BACKUP_DIR/$2' '$SAVE' &&
         sudo systemctl start dried-sea &&
         sleep 3 && sudo journalctl -u dried-sea -n 2 --no-pager"
    ;;
  *)
    echo "usage: server-cmd.sh {status|logs [N]|reset|backups|restore <file>}"; exit 1
    ;;
esac
