# Homelab

Docker Compose configuration and operating tools for a self-hosted Ubuntu server, referred to as `homeserver` in this repository.

## Services

The repository contains configuration for Traefik, Portainer, monitoring (Prometheus, Alertmanager, Grafana, node-exporter, cAdvisor), logging (Loki, Alloy), Gitea, n8n with PostgreSQL, Homepage, IT Tools, Uptime Kuma, and Blackbox monitoring. Each service or service group has its own directory.

Administrative web interfaces bind to `127.0.0.1` and are accessed through SSH tunnels, for example Portainer at `https://127.0.0.1:9443`. Traefik publishes Gitea, n8n, IT Tools and its dashboard on ports 80/443 behind an IP allowlist.

## Start here

- [Operating handbook](docs/operating-handbook.md): services, local configuration, certificates, routine operations, restore
- `scripts/`: health and security check, backups, image pinning, and server setup helpers. The scripts take the admin account from `ADMIN_USER` (default: the user who invoked `sudo`).
- Service-specific `.env.example` files and `monitoring/prometheus/targets/*.yml.example`: templates with placeholder values

Do not run all Compose projects blindly: configure the intended host, storage, service dependencies, and local environment first. Use the handbook for the deployment sequence.

## Repository conventions

Keep service configuration with its service. Keep cross-service operating procedures under `docs/` and reusable maintenance scripts under `scripts/`. Never commit live environment files, credentials, private keys or generated certificates. See [contributing conventions](CONTRIBUTING.md) and the [security policy](SECURITY.md).
