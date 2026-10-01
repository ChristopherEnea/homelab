# Homelab Agent Instructions

This repository defines a self-hosted homelab with Docker Compose. Keep changes small, explicit, reversible, and documented.

## Operating Rules

1. Inspect the relevant Compose file and current service state before changing anything.
2. Never expose secrets, tokens, private keys, or the contents of `.env` files in chat, logs, commits, or command output.
3. Treat host paths, named volumes, the Docker socket, TLS material, and the shared `traefik` network as production data.
4. Back up critical configuration and data before migrations, upgrades, or destructive operations.
5. Use the least privilege needed. Prefer read-only mounts where they are sufficient.
6. Do not remove volumes, delete data, stop production services, reboot hosts, or perform broad cleanup without explicit approval and a rollback plan.
7. Prefer pinned image versions when making a deliberate deployment change; do not silently broaden an upgrade.
8. Validate Compose configuration before applying it, then verify container health, routing, logs, and persistence after changes.
9. Do not assume a command is available on the host. Detect the platform and Docker Compose version first.
10. Report what was inspected or changed, the affected stack or host, verification results, and remaining risk.

## Repository Conventions

- Compose definitions live in `docker-compose/`; refer to the file by service or stack name.
- Most services route through Traefik using labels and the external `traefik` network.
- Preserve existing environment-variable substitution and document required variables without adding secret values.
- Keep persistent data in the existing named volume or bind-mount layout unless a migration is planned.
- Follow links and comments to upstream documentation when a service file is based on a vendor example.

## Workflow

### Change or Deploy a Service

Read the relevant skill in `.github/skills/`, inspect the current configuration and state, make a backup or rollback point, apply the smallest change, run `docker compose config`, and verify status, logs, routing, and data persistence.

### Troubleshoot

Start with observation: container status, health checks, recent logs, network membership, published ports, Traefik labels, disk space, and resource usage. Prefer reversible diagnostics before configuration changes.

### Maintain

Confirm backups and available disk space, update only the intended images or services, monitor startup and logs, and record the resulting versions and health state.