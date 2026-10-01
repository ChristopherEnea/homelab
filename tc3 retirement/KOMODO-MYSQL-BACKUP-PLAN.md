# Komodo MySQL Backup Plan

## Goal

Replace live MySQL Docker-volume archives with a database-aware backup workflow managed by Komodo.

The backup must produce a consistent, encrypted, restorable copy of the Semaphore database without copying MySQL's live data directory. The existing Docker-volume restore workflow remains useful for static volumes and cold database archives, but it should not be the primary backup method for a running MySQL instance.

## Scope

Initial target:

- Stack: `tc3-semaphore`
- Worker: `komodo-worker-tc3.christopherenea.net`
- MySQL service: `mysql`
- Database: `semaphore`
- S3-compatible storage: TrueNAS S3
- Backup format: compressed SQL dump encrypted before upload

Also protect the Semaphore configuration values required to interpret the restored database, especially:

- `SEMAPHORE_ACCESS_KEY_ENCRYPTION`
- `SEMAPHORE_DB_PASS`
- `MYSQL_PASSWORD`
- Semaphore administrator configuration
- S3 and GPG backup configuration

Secrets must be stored through Komodo's secret or variable mechanism and must not be committed to Git, placed in command history, or printed in logs.

## Proposed Architecture

```text
Komodo schedule
    |
    v
One-shot backup script on komodo-worker-tc3
    |
    v
Temporary mysql:8.0 client container
    |
    | connected to the tc3-semaphore Compose network
    v
mysqldump -> gzip -> GPG encryption -> S3 upload
```

The script should run on the worker because it can reach the Docker network and the MySQL service directly. It should use a temporary client container rather than adding a long-running backup service unless Komodo's execution model requires one.

The existing MySQL container remains running during normal backups. `mysqldump --single-transaction` provides a consistent snapshot for InnoDB tables without taking a long write lock.

## Komodo Integration

Create a Komodo Procedure or scheduled script execution with these characteristics:

- Runs on `komodo-worker-tc3`.
- Uses the `tc3-semaphore` Docker network.
- Receives secrets as injected environment variables or mounted secret files.
- Runs the backup script with a strict nonzero exit status on any failure.
- Emits only operational status, object name, byte count, and checksum.
- Never emits database passwords, GPG passphrases, S3 credentials, or SQL contents.
- Prevents overlapping executions.
- Sends failure notifications through the normal Komodo notification channel.

Recommended schedule:

- Daily logical backup during a low-traffic period.
- Retain at least 14 daily backups.
- Retain at least 8 weekly backups.
- Retain at least 12 monthly backups if storage permits.

Use UTC timestamps in object names to avoid ambiguity:

```text
semaphore/sql/semaphore-YYYYMMDDTHHMMSSZ.sql.gz.gpg
```

## Backup Script Design

Add a dedicated script to this directory, for example:

```text
backup-semaphore-mysql.sh
```

The script should:

1. Enable strict shell behavior.
2. Validate required variables and tool availability.
3. Refuse to run if the target container or network is missing.
4. Confirm that the MySQL service is reachable.
5. Run `mysqldump` with database-aware options.
6. Compress the dump.
7. Encrypt the compressed stream using GPG in batch mode.
8. Upload the encrypted object to S3 using a temporary file or a reliable streaming upload.
9. Verify that the uploaded object exists and has a nonzero size.
10. Write a checksum or manifest without exposing secret data.
11. Remove all local temporary files with a trap.
12. Return a nonzero exit status when any step fails.

The logical dump command should include:

```bash
mysqldump \
  --protocol=tcp \
  --host=mysql \
  --port=3306 \
  --user=semaphore \
  --password-file=/run/secrets/semaphore-db-password \
  --single-transaction \
  --quick \
  --routines \
  --events \
  --triggers \
  --hex-blob \
  --databases semaphore
```

The exact password-file option should be verified against the MySQL client version in the chosen image. If it is unavailable, pass the password through the client configuration file or environment in a way that does not expose it in process listings or logs.

The script must not use `--lock-all-tables` for the normal live backup path. Use a maintenance window and stop MySQL only for a deliberate cold-volume backup.

## Container Execution

Use a MySQL image matching the server major version, currently `mysql:8.0`, as the client image. The one-shot container should:

- Join the `tc3-semaphore` default network.
- Have no access to the Docker socket.
- Have no persistent database volume mounted.
- Receive only the minimum required secrets and S3 settings.
- Be removed automatically after completion.

Conceptually:

```bash
docker run --rm \
  --network tc3-semaphore_default \
  --env MYSQL_PWD_FILE=/run/secrets/semaphore-db-password \
  --mount type=bind,src=/secure/path/semaphore-db-password,dst=/run/secrets/semaphore-db-password,ro \
  mysql:8.0 \
  mysqldump --host=mysql ...
```

Prefer mounting a secret file over placing a password directly in the command arguments. Confirm the actual Compose network name with `docker network ls` before finalizing the script.

## Encryption and Storage

Encrypt before leaving the worker. Possible implementations:

- GPG symmetric encryption with a passphrase stored as a Komodo secret file.
- GPG public-key encryption with a backup recipient key and a separately protected private key.
- S3 server-side encryption as an additional layer, not a replacement for client-side encryption.

Use a modern authenticated GPG configuration supported by the installed GnuPG version. Record the key ID or cipher policy in documentation, but never record the passphrase.

Upload to a dedicated bucket or prefix, for example:

```text
s3://semaphore/semaphore/sql/
```

Use an S3 profile or injected credentials. Do not put credentials in the script. Configure lifecycle retention in S3 where possible, but keep application-level retention logic if the storage service does not provide reliable lifecycle rules.

## Configuration Backup

The SQL dump does not contain the full application configuration. Back up the required non-database configuration separately in an encrypted archive or secret store.

At minimum, preserve:

- The relevant Semaphore `.env` values.
- The Compose file and referenced inventory/authorized-key paths.
- The Semaphore image version used during the backup.
- The S3 endpoint, bucket, and object prefix.
- The GPG key or recipient identifier.
- The restore procedure and expected volume/service names.

Do not export the entire `.env` into regular logs. Create a redacted manifest containing variable names, not values, for restore documentation.

## Restore Workflow

A restore must always target a fresh MySQL data volume first.

1. Select an exact encrypted SQL backup from S3.
2. Download and decrypt it on a trusted operator workstation or worker path.
3. Create a new Docker volume.
4. Start a fresh `mysql:8.0` container with the Semaphore database and application credentials.
5. Wait for MySQL readiness.
6. Import the SQL dump.
7. Verify the expected schema and key row counts.
8. Start a temporary Semaphore container against the restored database.
9. Verify that the existing administrator account is present and the application starts.
10. Preserve the current production volume and create a safety archive.
11. Perform a controlled volume promotion only after validation passes.
12. Keep the old volume and safety archive until the application has been accepted in production.

Never overwrite the only copy of the production volume during the first import attempt.

## Validation Requirements

Every backup run should validate the backup artifact at least by:

- Confirming `mysqldump` exited successfully.
- Confirming decompression and GPG integrity checks pass.
- Confirming the uploaded object exists and is nonzero.
- Recording the dump timestamp and checksum.

A scheduled restore drill should validate more deeply:

- MySQL starts from a fresh volume.
- The `semaphore` schema exists.
- The table count matches the source at backup time.
- Semaphore migrations complete without destructive changes.
- The existing admin identity is recognized.
- A read-only application login works.
- A representative project and task can be viewed.

Do not run a destructive task against restored production data during a restore drill.

## Retention and Cleanup

The script should clean up only its own temporary files and containers. It must not delete production Docker volumes.

Recommended retention:

- 14 daily SQL backups.
- 8 weekly SQL backups.
- 12 monthly SQL backups.
- At least two recent tested restore points.
- At least one pre-promotion production volume archive during a migration.

Before deleting old backups, confirm that the current and previous scheduled runs succeeded. Failed uploads must not advance the retention window.

## Monitoring and Alerts

Komodo should alert when:

- The backup procedure exits nonzero.
- MySQL is unreachable.
- The dump is empty or unexpectedly small.
- The S3 upload fails.
- GPG encryption fails.
- The object verification step fails.
- A restore drill fails.
- The last successful backup is older than the allowed interval.

Keep logs useful but secret-free. A successful log should contain the backup object key, UTC timestamp, byte size, checksum, and duration.

## Implementation Phases

### Phase 1: Script and secret contract

- Define the Komodo variables and secret-file names.
- Implement `backup-semaphore-mysql.sh`.
- Add validation for network, container, credentials, S3 endpoint, and GPG configuration.
- Add traps and failure handling.

### Phase 2: Manual execution

- Run the script manually on the worker.
- Confirm the dump completes without stopping Semaphore.
- Confirm the encrypted object appears in the expected S3 prefix.
- Verify the object without printing its contents.

### Phase 3: Restore test

- Restore into a fresh MySQL volume.
- Start a temporary Semaphore container.
- Verify the database and application behavior.
- Record the exact commands and observed checks.

### Phase 4: Komodo schedule

- Add the script to a Komodo Procedure.
- Configure the schedule and notifications.
- Prevent concurrent runs.
- Run at least two scheduled executions and inspect their logs.

### Phase 5: Operational hardening

- Configure S3 lifecycle retention.
- Add a periodic restore drill.
- Document secret rotation.
- Pin or regularly review the MySQL client image version.
- Remove the MySQL volume from the generic live-volume backup job.

## What Not To Do

- Do not tar `/var/lib/mysql` while MySQL is running.
- Do not assume a new Docker volume fixes an inconsistent physical archive.
- Do not store passwords or GPG passphrases in the script.
- Do not pass secrets as visible command-line arguments when a secret file is available.
- Do not delete the old production volume until a restore has been validated.
- Do not treat a successful S3 upload as proof that the SQL dump is restorable.

## Relationship to This Directory

`restore-docker-volume-backup.sh` remains the restore tool for Docker-volume archives. The new database backup script should be separate because its input and validation model are different:

- Volume restore: archive layout, Docker volume extraction, container restart.
- MySQL backup: SQL consistency, encryption, import into a fresh data directory, schema/application validation.

Keep both procedures documented and clearly label any cold-volume MySQL backup as requiring MySQL to be stopped first.
