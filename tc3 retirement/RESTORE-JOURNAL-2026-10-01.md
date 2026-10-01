# Three Restores, Two Hosts, and One Very Important MySQL Lesson

*How a small homelab migration moved Homebox and FreshRSS, exposed a bad database backup, and reminded us that "the archive extracted successfully" is not the same as "the application is healthy."*

Over the course of September 30 and October 1, 2026, I worked through several data restores onto `komodo-worker-tc3.christopherenea.net`. The applications were different, but the shape of the work was consistent: identify the real persistence boundary, verify the archive before touching the live service, preserve a rollback copy, restore only the intended data, and validate the application afterward.

That pattern worked well. It also made the failures much easier to understand when one of the backups turned out to be fundamentally unsuitable for a database.

## Homebox: The Straightforward Restore

The first restore was Homebox. The target was the `homebox` container and its `tc3-homebox_homebox-data` Docker volume. The archive was plaintext and stored in the `homebox` S3-compatible bucket. Access was already configured through the `homebox-restore` AWS CLI profile, so there was no need to place credentials in commands or files.

The preflight checked the remote container and volume, selected the intended archive, and verified its structure before anything was replaced. The existing volume was preserved as a safety archive. With the container stopped, the backup contents were extracted into the volume, temporary transfer files were removed, and the container was restarted.

Homebox came back successfully. The important part was not that the extraction command returned zero; it was that the container could start with the restored data and pass the follow-up checks. The rollback archive remained available until the restore was considered safe.

## Semaphore: When a Volume Archive Is Not a Database Backup

Semaphore was the difficult restore. Its MySQL data lived in `tc3-semaphore_semaphore-mysql`, and the available archive looked like a normal Docker volume backup. The restore itself initially appeared to work: files were present in the volume and the container could be started.

MySQL quickly showed that the archive was not coherent. The restored data directory contained two InnoDB redo logs from different database histories:

```text
#ib_redo12
#ib_redo280
```

MySQL refused to use them together and entered a restart loop. Messages about the `mysql` hostname were secondary symptoms: the database was restarting, so the dependent Semaphore container had no stable service to connect to.

Before attempting a repair, the restored volume was preserved again at:

```text
/var/backups/tc3-semaphore_semaphore-mysql-before-restore-20260930151248.tar.gz
```

The conflicting redo directory was isolated for an experiment, but the repair path was not promoted into production. The original redo directory was restored and the container's original `unless-stopped` restart policy was re-enabled.

The root problem was the backup method. The backup container had archived `/var/lib/mysql` while MySQL was running. A file archive can faithfully copy files and still produce an unusable database if those files represent different moments in the database's internal history. For Semaphore, the durable solution is to stop MySQL before a filesystem backup or use a database-aware method such as a logical dump or a tool designed for physical MySQL backups.

This was the most useful failure of the migration: it turned a vague restore problem into a clear rule. A live database directory is not automatically a valid backup just because every file made it into the tarball.

## RSS: Finding the Real Persistence Boundary

The RSS move began with a source-host question: was the data in a Docker volume, a bind mount, or both? The new Compose project, `tc3-rss`, had two services:

- `fresh-rss`, using `/etc/fresh-rss:/config`
- `full-text-rss`, using the separate volume `tc3-rss_rss-cache`

The available archive contained paths such as `/backup/fresh-rss/www/freshrss/data`, which identified it as a FreshRSS configuration backup. It was not a backup of the `full-text-rss` cache volume.

That distinction prevented a tempting but incorrect restore. Copying the FreshRSS archive into `tc3-rss_rss-cache` would have put the right data in the wrong application. Instead, the existing destination directory was moved aside to preserve a rollback point:

```text
/etc/fresh-rss.before-restore-20261001-174104
```

The archive was transferred to the new worker, extracted into `/etc/fresh-rss`, and cleaned up afterward. Only `fresh-rss` was started; `full-text-rss` was intentionally left stopped.

The initial validation command hit a small operational snag: fish loop syntax was accidentally sent to the worker's Bash shell, so the command failed before it could start anything. Nothing was changed by that failed command. A POSIX-compatible check was run next, FreshRSS started normally, and its initialization logs were clean.

The final route check returned HTTP `200`, with the expected redirect from `/` to `/i/`. The container had restart count `0`. The image generated new internal self-signed keys during initialization, but Traefik continued to handle external HTTPS, so that did not prevent the application from coming up.

## What the Restores Taught Me

The safest part of the process was the discipline around boundaries and rollback copies:

1. **Preflight the archive and the target.** Confirm the container, volume or bind mount, archive type, archive root, and expected application data before restoring.
2. **Preserve the current state first.** A restore without a rollback copy turns a recoverable mistake into a second incident.
3. **Match the backup to the persistence model.** Docker volumes, host bind mounts, caches, and database files are not interchangeable merely because they are all stored on disk.
4. **Treat databases as databases.** MySQL needs a consistent snapshot, not just a collection of files copied while it is changing.
5. **Validate the service, not just the archive.** A successful tar extraction says nothing about whether the application can start, connect to its database, or answer through its public route.
6. **Keep experiments isolated.** The Semaphore repair was attempted only after preserving the restored volume, and the original data was put back when the experiment was not ready for production.

The n8n work during the same period was diagnostic only. It found duplicate running containers advertising the same Traefik hostname, but no n8n containers, Compose files, Traefik settings, or DNS records were changed.

The resulting restore workflow is now documented in `SKILL.md` and implemented by `restore-docker-volume-backup.sh`. The scripts handle both plaintext and GPG-encrypted archives, but the Semaphore incident is the reminder that archive mechanics are only one part of recovery. The backup has to be valid for the application it is meant to save.
