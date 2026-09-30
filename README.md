# odoo-actions

Composite actions shared by every client repo. Each client keeps only the thin callers in
`templates/`, copied to `.github/workflows/` unchanged; everything client-specific lives in
repo/environment variables.

| Action | Used by |
|---|---|
| `build` | deploy.yml `build` job |
| `deploy` | deploy.yml `deploy` job |
| `backup` | backup.yml |
| `module-upgrade` | deploy.yml `upgrade` job (changed modules), module-upgrade.yml (forced `-u`) |
| `ssl-renew` | maintenance.yml |

`bin/odoo-run` clones image, network and mounts from the live `<stack>_odoo` service, so no
workflow names a network or volume.

## Where the image is built

| | Client with Docker Hub | Client without a registry |
|---|---|---|
| `IMAGE_REPO` | `acme/odoo` | unset |
| Build runs on | GitHub-hosted runner | the client's server (`RUNNER`) |
| Image | pushed as `acme/odoo:<sha>` and `:<branch>` | kept locally as `localhost/<repo>:<sha>` |
| `DOCKER_USER` / `DOCKER_PAT` | client's account (push + pull) | only if the base image is private on Docker Hub |
| Rollback | re-run an old deploy (pulls the old sha) | re-run an old deploy (rebuilds the old sha) |

The `localhost/` prefix keeps swarm from ever pulling a same-named public image from Docker Hub.
Server builds use the production host's CPU and memory while they run.

## Per-client setup

Repo variables:

| Variable | Meaning | Default |
|---|---|---|
| `RUNNER` | self-hosted runner label | — |
| `IMAGE_REPO` | registry repo to push to; unset builds on the server | unset |
| `BASE_IMAGE` | image passed as `BASE_IMAGE` | `muritechnologies/odoo-enterprise:18.0` |
| `BUILDER` | Docker Build Cloud endpoint; unset uses buildx with the GitHub Actions cache | unset |

Environments `production` (branch `main` only) and `stage`, each with:

| Variable | Example | Default |
|---|---|---|
| `STACK` | `acme` | — |
| `MAIN_DB` | `acme_prod` | — |
| `UPGRADE_DB` | `acme_prod,acme_test` | every database on the image's Odoo series |
| `NETWORK` | `odoo_swarm` / `stage_swarm` | `odoo_swarm` |
| `COMPOSE_FILE` | `stage-compose.yml` | `docker-compose.yml` |
| `PROJECT_DIR` | `/home/odoo/stage` | `/home/odoo/odoo` |
| `BACKUP_DIR` | | `/home/odoo/backups` |

Do not add required reviewers to `production`: scheduled backups and maintenance run in it and
would wait for approval.

Secrets: `DOCKER_USER`, `DOCKER_PAT` (see the table above for when they are needed).

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
