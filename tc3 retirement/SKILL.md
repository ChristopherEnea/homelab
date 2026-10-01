---
name: docker-volume-restore
description: "Use when restoring a Docker volume from an offen/docker-volume-backup archive stored in S3 or an S3-compatible service. Guides safe use of restore-docker-volume-backup.sh, including selecting an archive, validating its layout, preserving the current volume, stopping and restarting a container, and verifying the result."
---

# Docker Volume Restore

Use `restore-docker-volume-backup.sh` to restore a Docker volume backup to a remote Docker worker. The script is designed to run locally, where the S3 endpoint is reachable, and uses SSH to perform the volume operation on the worker.

## Prerequisites

Install or make available locally:

- AWS CLI (`aws`)
- GnuPG (`gpg`) for encrypted backups; omit it for plaintext backups
- SSH access to the Docker worker
- `sudo -n docker` access for the SSH user
- `scp` and `tar`

Configure S3 credentials through the AWS CLI credential chain. Prefer an AWS profile or environment variables. Do not copy credentials into this skill, the script, shell history, or command arguments.

To configure a dedicated AWS CLI profile on macOS:

```bash
aws configure --profile paperless-restore
```

Enter the S3 access key and secret when prompted. A region such as `us-east-1` and output format `json` are suitable defaults. Verify access without printing credentials:

```bash
AWS_PROFILE=paperless-restore aws --endpoint-url https://truenas.christopherenea.net:30292 \
  s3api list-objects-v2 --bucket paperless \
  --query 'Contents[].{Key:Key,LastModified:LastModified,Size:Size}' --output table
```

Use the same profile for each restore invocation by prefixing the command with `AWS_PROFILE=paperless-restore`. If the credentials have previously appeared in terminal output or logs, rotate them before configuring the profile.

For a GPG-encrypted archive, store the passphrase in a local file readable only by your account:

```bash
./create-gpg-passphrase-file.sh
```

The helper defaults to `~/.paperless-gpg-passphrase`, prompts for the passphrase twice without displaying it, and creates the file with mode `600`. Use `--output PATH` for a different location or `--force` to replace an existing file:

```bash
./create-gpg-passphrase-file.sh --output "$HOME/.paperless-gpg-passphrase"
```

Do not put the passphrase in the restore command, shell history, this skill, or chat. The script reads the file through GnuPG's `--passphrase-file` option and removes the downloaded encrypted and decrypted archives when it exits.

The remote user must be able to run these commands without an interactive sudo prompt:

```bash
sudo -n docker inspect
sudo -n docker volume inspect
sudo -n docker stop
sudo -n docker start
sudo -n tar
```

Make the script executable once:

```bash
chmod +x restore-docker-volume-backup.sh
```

## Standard Usage

Run from this directory:

```bash
./restore-docker-volume-backup.sh \
  --host WORKER_HOST \
  --ssh-user SSH_USER \
  --container CONTAINER_NAME \
  --volume DOCKER_VOLUME \
  --bucket S3_BUCKET \
  --endpoint https://S3_ENDPOINT \
  --gpg-passphrase-file /path/to/paperless-gpg-passphrase
```

The `--gpg-passphrase-file` option is only required for GPG-encrypted archives. For a plaintext `.tar.gz` backup, omit that option and the script will validate and restore the downloaded archive directly.

The script selects the newest object in the bucket unless `--backup` is supplied. It then:

1. Checks that the remote container and volume exist.
2. Downloads the encrypted archive locally through the AWS CLI.
3. Decrypts it locally with GnuPG and validates that the result is a gzip tar archive containing the expected volume directory.
4. Requests confirmation before changing the live volume.
5. Transfers the archive to the worker.
6. Creates a pre-restore tar backup under `/var/backups` on the worker.
7. Stops the container if it was running.
8. Extracts the saved volume contents.
9. Removes the temporary archive from the worker.
10. Restarts the container if it was running and reports its status.

The current volume backup is not automatically deleted. The script prints its path after a successful restore.

## Flame Example

For the Flame dashboard setup used on `komodo-worker-tc3`:

```bash
./restore-docker-volume-backup.sh \
  --host komodo-worker-tc3.christopherenea.net \
  --ssh-user cenea \
  --container flame \
  --volume dashboard_flame \
  --bucket flame \
  --endpoint https://truenas.christopherenea.net:30292 \
  --archive-root flame \
  --no-verify-ssl
```

`--archive-root flame` is important for this backup. The archive contains paths like:

```text
/backup/flame/config.json
/backup/flame/db.sqlite
/backup/flame/uploads/...
```

The destination volume is named `dashboard_flame`, so the archive root is not the same as the Docker volume name.

Use `--backup` to restore a specific archive instead of the newest one:

```bash
./restore-docker-volume-backup.sh \
  --host komodo-worker-tc3.christopherenea.net \
  --ssh-user cenea \
  --container flame \
  --volume dashboard_flame \
  --bucket flame \
  --backup backup-2026-09-22T02-00-00.tar.gz \
  --archive-root flame \
  --no-verify-ssl
```

Use `--yes` only for an already-reviewed, repeatable restore. The default confirmation prompt is intentional because the volume contents are replaced.

For the Paperless backup, run the script once for each volume using the same `--backup` value after inspecting the available objects. The archive roots and volumes are:

```text
tc3-paperless-ngx_data      paperless-data-backup
tc3-paperless-ngx_media     paperless-media-backup
tc3-paperless-ngx_redisdata paperless-redisdata-backup
```

## Mapping Another Stack

Before running the script, identify the values from the stack definition and backup container:

```bash
ssh SSH_USER@WORKER_HOST \
  'sudo -n docker inspect BACKUP_CONTAINER TARGET_CONTAINER \
   --format "{{.Name}} {{json .Mounts}} {{json .Config.Env}}"'
```

Map:

- `--host`: SSH hostname of the Docker worker
- `--ssh-user`: SSH account with passwordless Docker sudo
- `--container`: live application container using the volume
- `--volume`: Docker volume mounted by that container
- `--bucket`: value of `AWS_S3_BUCKET_NAME`
- `--endpoint`: value of `AWS_ENDPOINT`, prefixed with `https://` unless the storage service uses plain HTTP
- `--archive-root`: directory beneath `/backup/` in the tar archive
- `--backup`: exact archive key when a specific restore point is required

Inspect an archive before restoring it when the root directory is uncertain:

```bash
tar -tzf /path/to/backup.tar.gz | head -50
```

## Network Considerations

The AWS CLI runs on the local machine. This is useful when the Docker worker cannot reach the S3 endpoint but the local machine can. The script downloads locally first, then transfers the archive over SSH.

If S3 access fails:

```bash
aws s3api list-objects-v2 \
  --bucket S3_BUCKET \
  --endpoint-url https://S3_ENDPOINT
```

Check endpoint reachability from the local machine and worker separately. A successful SSH connection does not imply that the worker can reach the S3 service.

Use `--no-verify-ssl` only when the endpoint has a deliberately self-signed or otherwise untrusted certificate. Prefer installing the correct CA certificate and omit this option when possible.

## Safety Rules

- Confirm the container and volume mapping before accepting the restore prompt.
- Use `--backup` when restoring a known point in time; do not rely on newest-object selection during an incident unless that is intended.
- Keep the printed `/var/backups/*-before-restore-*.tar.gz` file until the restore is verified.
- Do not restore into a volume while its application container is running.
- Do not use this workflow for the wrong stack or an unrelated volume.
- Rotate any S3 credentials that have appeared in terminal output, logs, screenshots, or chat history.

## Troubleshooting

### `sudo: a password is required`

Configure passwordless sudo for the required Docker and archive commands, or run the workflow with an account that already has it. The script intentionally does not handle interactive sudo prompts.

### `no backup objects found`

Check the bucket name, AWS profile, endpoint, and credentials. List the bucket directly with the AWS CLI.

### `archive does not contain the expected ... tree`

Inspect the archive with `tar -tzf` and pass the directory beneath `/backup/` using `--archive-root`. For example, use `--archive-root flame` when the volume being restored is named `dashboard_flame` but the archive directory is `flame`.

### S3 connection timeout from the worker

The script does not query S3 from the worker. It queries S3 locally and only requires the worker to accept SSH and Docker commands. If the local machine also cannot reach S3, fix the network route or use a machine that can reach the storage endpoint.

### Container does not restart

The script reports the container state and preserves the pre-restore archive. Inspect the container directly:

```bash
ssh SSH_USER@WORKER_HOST \
  'sudo -n docker ps -a --filter name=CONTAINER_NAME; sudo -n docker logs --tail 100 CONTAINER_NAME'
```

Do not delete the pre-restore volume archive until the application has been verified.
