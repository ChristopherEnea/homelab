---
name: homelab-monitoring
description: "Use when checking homelab health, diagnosing a failed container or route, analyzing Docker logs, or reviewing CPU, memory, disk, network, and backup status."
---

# Homelab Monitoring

## Diagnostic Order

1. Establish scope: affected stack, service, host, start time, and recent changes.
2. Check resources and Docker state before changing configuration.
3. Inspect recent service logs and health status, then dependencies, networks, mounts, ports, and Traefik labels.
4. Compare the running state with the Compose definition and expected environment variables without printing secret values.
5. Make one reversible change at a time and repeat the health checks.

## Useful Checks

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker stats --no-stream
docker system df
docker compose -f <file> ps
docker compose -f <file> logs --tail=100 <service>
df -h
```

Check routing through the intended hostname and inspect Traefik logs when a service is reachable locally but not through HTTPS. Escalate suspected data loss, certificate compromise, or sustained resource exhaustion before taking disruptive action.