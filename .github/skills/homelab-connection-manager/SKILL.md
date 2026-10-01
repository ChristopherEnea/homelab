---
name: homelab-connection-manager
description: "Use when connecting to, transferring files to, or authenticating with a homelab host over SSH, including identity verification and secure troubleshooting."
---

# Homelab Connection Manager

## Procedure

1. Confirm the intended host, environment, account, and change scope.
2. Verify the hostname, expected host key, and HTTPS certificate where applicable.
3. Prefer SSH keys and an existing SSH config entry. Never request or print passwords, tokens, or private keys.
4. Establish the least-privileged session and confirm access with a read-only command.
5. Use `scp` or `rsync` only for the required paths; avoid broad transfers and preserve permissions deliberately.
6. Close or clean up sessions and report the host, access method, checks performed, and any unresolved risk.

## Useful Checks

```bash
ssh -G <host>
ssh -o BatchMode=yes <host> 'hostname && id'
ssh <host> 'docker version && docker compose version'
```

Do not use `ssh-keyscan` as proof of identity. Compare a key fingerprint with a trusted source before accepting a new host key.