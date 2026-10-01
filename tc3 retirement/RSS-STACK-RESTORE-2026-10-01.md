# Restore History

This record summarizes the data restores completed during the September 30 to October 1, 2026 migration work. Credentials and passphrases are intentionally omitted.

## Homebox

- **Destination:** `komodo-worker-tc3.christopherenea.net`
- **Container:** `homebox`
- **Volume:** `tc3-homebox_homebox-data`
- **Source:** plaintext archive from the `homebox` S3-compatible bucket, accessed with the configured `homebox-restore` AWS profile
- **Result:** restore completed successfully

The pre-restore volume contents were preserved before replacement. The archive was validated, extracted into the Docker volume while the container was stopped, and the container was restarted and checked afterward. The original safety archive was retained for rollback.

## Semaphore

- **Destination:** `komodo-worker-tc3.christopherenea.net`
- **Volume:** `tc3-semaphore_semaphore-mysql`
- **Result:** physical volume restore exposed an inconsistent MySQL data directory; repair was attempted and the original redo directory was restored

The restored archive contained incompatible InnoDB redo logs from different database states. MySQL consequently entered a restart loop. Before repair work, the volume was preserved at:

```text
/var/backups/tc3-semaphore_semaphore-mysql-before-restore-20260930151248.tar.gz
```

The redo directory was isolated for testing, then restored after the repair experiment. The container restart policy was re-enabled. The incident showed that a live MySQL data directory must not be backed up as a raw Docker volume; future Semaphore backups should stop MySQL first or use a database-aware logical/physical backup method.

## RSS / FreshRSS

- **Date:** 2026-10-01
- **Destination:** `komodo-worker-tc3.christopherenea.net`
- **Compose project:** `tc3-rss`
- **Source archive:** `s3://rss/backup-2026-10-01T13-44-28.tar.gz`
- **Target:** `/etc/fresh-rss:/config` for `fresh-rss`

The plaintext archive was preflighted and verified to contain `/backup/fresh-rss`. The existing destination directory was preserved at:

```text
/etc/fresh-rss.before-restore-20261001-174104
```

The archive was extracted into `/etc/fresh-rss`, preserving file metadata. Temporary archive and staging files were removed from the worker afterward.

Validation succeeded:

- `fresh-rss` started and remained running with restart count `0`.
- Startup logs completed without errors.
- The Traefik route returned HTTP `200` for `fresh-rss.christopherenea.net`.
- FreshRSS returned its expected redirect from `/` to `/i/`.
- `full-text-rss` remained stopped intentionally.

The `rss_rss-cache` Docker volume was not copied because it belongs to the separate Full-Text RSS service and was unrelated to the FreshRSS archive. The FreshRSS image generated new internal self-signed keys during initialization; external HTTPS continues to be handled by Traefik.

## General Procedure

Each restore used the same safety pattern where applicable: preflight the archive and target mapping, stop the dependent service, preserve the current data, replace only the intended data path, remove temporary transfer files, restart the service, and verify its state and application endpoint. The reusable procedure is documented in `SKILL.md` and implemented by `restore-docker-volume-backup.sh`.

The n8n investigation was read-only and is not included as a restore. No n8n containers, Compose files, Traefik configuration, or DNS records were changed.
