---
name: homelab-system-admin
description: "Use when deploying, updating, restarting, or changing Docker Compose services, host packages, filesystems, users, permissions, backups, or scheduled maintenance in the homelab."
---

# Homelab System Administration

## Compose Change Procedure

1. Read the target file and inspect the current containers, images, networks, volumes, disk space, and backups.
2. Identify whether the change is reversible and make a backup or rollback point before modifying persistent state.
3. Apply the smallest targeted edit. Keep secrets in environment variables and do not change unrelated services.
4. Validate with `docker compose -f <file> config`.
5. Use the narrowest action: `pull`, `up -d <service>`, or a controlled restart. Do not use `down -v` unless explicitly approved.
6. Verify container status, health, logs, Traefik routing, and data persistence.

## Host Changes

Detect the operating system and available tools before using `systemctl`, package managers, filesystem commands, or scheduled-task tools. Follow least privilege, back up critical configuration, and test in staging before production.

## Reporting

Record the stack and services affected, image or configuration changes, backup or rollback reference, validation commands, and post-change health results.