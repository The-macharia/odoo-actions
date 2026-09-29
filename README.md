# odoo-actions

Composite actions shared by every client repo. Each client keeps only the thin callers in
`templates/`, copied to `.github/workflows/` unchanged; everything client-specific lives in
repo/environment variables.

| Action | Used by |
|---|---|
| `build` | deploy.yml (GitHub-hosted) |
| `deploy` | deploy.yml (server) |
| `backup` | backup.yml |
| `module-upgrade` | module-upgrade.yml |
| `ssl-renew` | maintenance.yml |

`bin/odoo-run` clones image, network and mounts from the live `<stack>_odoo` service, so no
workflow names a network or volume.

## Per-client setup

Repo variable: `RUNNER` (self-hosted runner label).

Environments `production` (branch `main` only) and `stage`, each with:

| Variable | Example | Default |
|---|---|---|
| `STACK` | `acme` | — |
| `MAIN_DB` | `acme_prod` | — |
| `NETWORK` | `odoo_swarm` / `stage_swarm` | `odoo_swarm` |
| `COMPOSE_FILE` | `stage-compose.yml` | `docker-compose.yml` |
| `PROJECT_DIR` | `/home/odoo/stage` | `/home/odoo/odoo` |
| `BACKUP_DIR` | | `/home/odoo/backups` |

Do not add required reviewers to `production`: scheduled backups and maintenance run in it and
would wait for approval.

Secrets: `DOCKER_USER`, `DOCKER_PAT`.

The compose file joins the external network the deploy action creates:

```yaml
networks:
  odoo_swarm:
    external: true
```

Stacks sharing a host (prod + stage, or two clients on one server) need distinct networks, otherwise the
`db` service name resolves across stacks.

## Releasing

Tag `v1` and move it on each compatible release; callers pin `@v1`.

## Other workflows in this repo

`.github/workflows/image_builder.yml` builds the root `Dockerfile` to GHCR; `module_migrator.yml`
is a stub for migrating module repos between Odoo versions.
