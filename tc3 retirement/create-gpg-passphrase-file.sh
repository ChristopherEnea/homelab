#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_FILE="${HOME}/.paperless-gpg-passphrase"
FORCE='false'

usage() {
  cat <<'EOF'
Usage:
  create-gpg-passphrase-file.sh [--output FILE] [--force]

Options:
  --output FILE  Passphrase file to create
                 Default: ~/.paperless-gpg-passphrase
  --force        Replace an existing passphrase file
  -h, --help     Show this help

The passphrase is entered twice without being displayed.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || fail 'missing value for --output'
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --force)
      FORCE='true'
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$OUTPUT_FILE" ]] || fail 'output path must not be empty'
if [[ -e "$OUTPUT_FILE" || -L "$OUTPUT_FILE" ]] && [[ "$FORCE" != 'true' ]]; then
  fail "output file already exists: $OUTPUT_FILE (use --force to replace it)"
fi

OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
[[ -d "$OUTPUT_DIR" ]] || fail "output directory does not exist: $OUTPUT_DIR"
[[ -w "$OUTPUT_DIR" ]] || fail "output directory is not writable: $OUTPUT_DIR"

printf 'Enter the GPG passphrase: ' >&2
IFS= read -r -s PASSPHRASE
printf '\nRe-enter the GPG passphrase: ' >&2
IFS= read -r -s CONFIRMATION
printf '\n' >&2

[[ -n "$PASSPHRASE" ]] || fail 'passphrase must not be empty'
[[ "$PASSPHRASE" == "$CONFIRMATION" ]] || fail 'passphrases do not match'

TEMP_FILE="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")" || fail 'could not create temporary passphrase file'
cleanup() {
  rm -f "$TEMP_FILE"
}
trap cleanup EXIT

chmod 600 "$TEMP_FILE"
printf '%s\n' "$PASSPHRASE" > "$TEMP_FILE"
unset PASSPHRASE CONFIRMATION

if [[ "$FORCE" == 'true' ]]; then
  mv -f "$TEMP_FILE" "$OUTPUT_FILE"
else
  mv "$TEMP_FILE" "$OUTPUT_FILE"
fi
trap - EXIT

printf 'Created %s with mode 600.\n' "$OUTPUT_FILE"
