#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  restore-docker-volume-backup.sh \
    --host SSH_HOST \
    --container CONTAINER \
    --volume VOLUME \
    --bucket S3_BUCKET \
    [options]

Required:
  --host HOST            SSH host for the Docker worker
  --container NAME       Container that uses the volume
  --volume NAME          Docker volume to restore
  --bucket NAME          S3 bucket containing the backup archives

Options:
  --endpoint URL         S3-compatible endpoint
                         Default: https://truenas.christopherenea.net:30292
  --backup KEY           Exact S3 object key; defaults to newest object
  --archive-root NAME    Directory inside the archive to restore
                         Default: volume name
  --gpg-passphrase-file FILE
                         File containing the GPG passphrase for an encrypted backup
  --ssh-user USER        SSH user; default is the current local user
  --ssh-port PORT        SSH port; default is 22
  --no-verify-ssl        Disable TLS certificate verification for S3
  --yes                  Skip the confirmation prompt
  -h, --help             Show this help

AWS credentials must be available to the local AWS CLI through an AWS profile,
environment variables, or another supported AWS CLI credential provider.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

HOST=''
CONTAINER=''
VOLUME=''
BUCKET=''
ENDPOINT='https://truenas.christopherenea.net:30292'
BACKUP_KEY=''
ARCHIVE_ROOT=''
GPG_PASSPHRASE_FILE=''
SSH_USER="${USER:-$(id -un)}"
SSH_PORT='22'
VERIFY_SSL='true'
ASSUME_YES='false'

while (($#)); do
  case "$1" in
    --host) HOST="${2:?Missing value for --host}"; shift 2 ;;
    --container) CONTAINER="${2:?Missing value for --container}"; shift 2 ;;
    --volume) VOLUME="${2:?Missing value for --volume}"; shift 2 ;;
    --bucket) BUCKET="${2:?Missing value for --bucket}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?Missing value for --endpoint}"; shift 2 ;;
    --backup) BACKUP_KEY="${2:?Missing value for --backup}"; shift 2 ;;
    --archive-root) ARCHIVE_ROOT="${2:?Missing value for --archive-root}"; shift 2 ;;
    --gpg-passphrase-file) GPG_PASSPHRASE_FILE="${2:?Missing value for --gpg-passphrase-file}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:?Missing value for --ssh-user}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?Missing value for --ssh-port}"; shift 2 ;;
    --no-verify-ssl) VERIFY_SSL='false'; shift ;;
    --yes) ASSUME_YES='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$HOST" ]] || fail '--host is required'
[[ -n "$CONTAINER" ]] || fail '--container is required'
[[ -n "$VOLUME" ]] || fail '--volume is required'
[[ -n "$BUCKET" ]] || fail '--bucket is required'
[[ "$VOLUME" != */* && "$ARCHIVE_ROOT" != */* ]] || fail 'volume and archive-root must be single directory names'
[[ -n "$ARCHIVE_ROOT" ]] || ARCHIVE_ROOT="$VOLUME"
if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
  [[ -f "$GPG_PASSPHRASE_FILE" && -r "$GPG_PASSPHRASE_FILE" ]] || fail 'GPG passphrase file must be a readable regular file'
fi

command -v aws >/dev/null || fail 'aws CLI is required locally'
command -v ssh >/dev/null || fail 'ssh is required locally'
command -v scp >/dev/null || fail 'scp is required locally'
command -v tar >/dev/null || fail 'tar is required locally'

if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
  command -v gpg >/dev/null || fail 'gpg is required when --gpg-passphrase-file is used'
fi

SSH_TARGET="${SSH_USER}@${HOST}"
AWS_ARGS=(--endpoint-url "$ENDPOINT")
[[ "$VERIFY_SSL" == 'true' ]] || AWS_ARGS+=(--no-verify-ssl)
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/docker-volume-restore.XXXXXXXX")"
REMOTE_ARCHIVE="/tmp/docker-volume-restore-$(date '+%Y%m%d%H%M%S').tar.gz"
REMOTE_CURRENT_BACKUP="/var/backups/${VOLUME}-before-restore-$(date '+%Y%m%d%H%M%S').tar.gz"
LOCAL_ENCRYPTED_ARCHIVE="$WORK_DIR/backup.encrypted"
LOCAL_ARCHIVE="$WORK_DIR/backup.tar.gz"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

log 'Checking remote Docker access and target volume'
ssh -p "$SSH_PORT" "$SSH_TARGET" \
  "sudo -n docker volume inspect '$VOLUME' >/dev/null && sudo -n docker inspect '$CONTAINER' >/dev/null" \
  || fail 'remote Docker checks failed; verify SSH, sudo, container, and volume names'

if [[ -z "$BACKUP_KEY" ]]; then
  log "Finding newest backup in s3://$BUCKET"
  BACKUP_KEY="$(aws "${AWS_ARGS[@]}" s3api list-objects-v2 \
    --bucket "$BUCKET" \
    --query 'Contents | sort_by(@, &LastModified) | [-1].Key' \
    --output text)"
  [[ "$BACKUP_KEY" != 'None' && -n "$BACKUP_KEY" ]] || fail 'no backup objects found in the S3 bucket'
fi

log "Downloading s3://$BUCKET/$BACKUP_KEY"
aws "${AWS_ARGS[@]}" s3 cp "s3://$BUCKET/$BACKUP_KEY" "$LOCAL_ENCRYPTED_ARCHIVE"

if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
  log 'Decrypting archive'
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase-file "$GPG_PASSPHRASE_FILE" \
    --output "$LOCAL_ARCHIVE" \
    --decrypt "$LOCAL_ENCRYPTED_ARCHIVE" \
    || fail 'unable to decrypt backup; verify the GPG passphrase file and archive'
else
  log 'Using plaintext archive'
  mv "$LOCAL_ENCRYPTED_ARCHIVE" "$LOCAL_ARCHIVE"
fi

log 'Validating archive'
ARCHIVE_ENTRIES="$(tar -tzf "$LOCAL_ARCHIVE")" || fail 'backup is not a readable gzip-compressed tar archive'
printf '%s\n' "$ARCHIVE_ENTRIES" | awk -v root="$ARCHIVE_ROOT" '
  $0 == "/backup/" || $0 == "/backup/" root "/" || index($0, "/backup/" root "/") == 1 { found=1 }
  END { exit(found ? 0 : 1) }
' || fail "archive does not contain the expected /backup/$ARCHIVE_ROOT tree"
printf '%s\n' "$ARCHIVE_ENTRIES" | grep -Eq '(^|/)\.\.?(/|$)' && fail 'archive contains unsafe dot-path entries'

log "Archive selected: $BACKUP_KEY"
log "Target: $SSH_TARGET, container=$CONTAINER, volume=$VOLUME"
if [[ "$ASSUME_YES" != 'true' ]]; then
  printf 'This will stop %s, replace its volume contents, and restart it. Continue? [y/N] ' "$CONTAINER"
  read -r answer
  [[ "$answer" == 'y' || "$answer" == 'Y' ]] || { log 'Restore cancelled'; exit 0; }
fi

log 'Transferring archive to worker'
scp -P "$SSH_PORT" "$LOCAL_ARCHIVE" "$SSH_TARGET:$REMOTE_ARCHIVE"

log 'Restoring volume on worker'
ssh -p "$SSH_PORT" "$SSH_TARGET" \
  "REMOTE_ARCHIVE='$REMOTE_ARCHIVE' REMOTE_CURRENT_BACKUP='$REMOTE_CURRENT_BACKUP' CONTAINER='$CONTAINER' VOLUME='$VOLUME' ARCHIVE_ROOT='$ARCHIVE_ROOT' bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

running='false'
status="$(sudo -n docker inspect -f '{{.State.Status}}' "$CONTAINER")"
[[ "$status" == 'running' ]] && running='true'

sudo -n mkdir -p "$(dirname "$REMOTE_CURRENT_BACKUP")"
sudo -n tar -czf "$REMOTE_CURRENT_BACKUP" -C "/var/lib/docker/volumes/$VOLUME/_data" .

if [[ "$running" == 'true' ]]; then
  sudo -n docker stop "$CONTAINER" >/dev/null
fi

sudo -n tar -xzf "$REMOTE_ARCHIVE" \
  -C "/var/lib/docker/volumes/$VOLUME/_data" \
  --strip-components=2 \
  "/backup/$ARCHIVE_ROOT"

rm -f "$REMOTE_ARCHIVE"

if [[ "$running" == 'true' ]]; then
  sudo -n docker start "$CONTAINER" >/dev/null
  for attempt in {1..15}; do
    status="$(sudo -n docker inspect -f '{{.State.Status}}' "$CONTAINER")"
    [[ "$status" == 'running' ]] && break
    sleep 1
  done
fi

status="$(sudo -n docker inspect -f '{{.State.Status}}' "$CONTAINER")"
[[ "$status" == 'running' || "$running" == 'false' ]] || {
  printf 'Container failed to return to running state: %s\n' "$status" >&2
  exit 1
}

printf 'Restore complete. Current volume backup: %s\n' "$REMOTE_CURRENT_BACKUP"
printf 'Container status: %s\n' "$status"
sudo -n find "/var/lib/docker/volumes/$VOLUME/_data" -maxdepth 2 -type f -printf '%P %s bytes\n' | sort
REMOTE_SCRIPT

log 'Restore finished successfully'
