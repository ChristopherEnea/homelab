---
description: "Docker Compose guidance for homelab service definitions"
applyTo: "docker-compose/**/*.yml,docker-compose/**/*.yaml"
---

# Compose Guidance

- Preserve valid Compose structure and the file's existing quoting and indentation style.
- Run `docker compose -f <file> config` before deployment. Use `--quiet` when only validation is needed.
- Check `docker compose -f <file> ps`, `logs --tail=100`, and relevant service configuration after applying changes.
- Keep Traefik labels consistent: router host rule, TLS, certificate resolver, backend port, and `traefik.docker.network` where multiple networks are present.
- Treat `traefik` as an external shared network. Do not create, rename, or remove it from an individual stack without explicit approval.
- Preserve named volumes and bind mounts. Call out any change that could migrate, overwrite, or orphan data.
- Use `${VARIABLE}` for secrets and deployment-specific values; never commit literal credentials.
- Review `depends_on`, networks, exposed ports, restart policies, and health checks when changing service dependencies.
- Prefer explicit image tags for intentional changes and record the reason for updates.