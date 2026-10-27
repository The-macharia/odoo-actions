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
| `restart-stack` | restart-stack.yml: removes the stack and redeploys it with the image it was running |
| `ssl-renew` | maintenance.yml |
| `observer` | observer.yml: Prometheus, Loki, Grafana and exporters next to the stack (see [Observer](#observer)) |

`bin/odoo-run` clones image, network and mounts from the live `<stack>_odoo` service, so no
workflow names a network or volume.

## Where the image is built

| | Client with Docker Hub | Client without a registry |
|---|---|---|
| `IMAGE_REPO` | `acme/odoo` | unset |
| Build runs on | GitHub-hosted runner | the client's server (`RUNNER`) |
| Image | deployed as `acme/odoo:<branch>`, also pushed as `:<sha>` | kept locally as `localhost/<repo>:<sha>` |
| `DOCKER_USER` / `DOCKER_PAT` | client's account (push + pull) | only if the base image is private on Docker Hub |
| Rollback | re-run all jobs of an old deploy (rebuilds the old sha as `:<branch>`) | re-run an old deploy (rebuilds the old sha) |

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
| `SUBMODULES` | `true` builds with submodules (shared modules such as `oo_fleet_management`) at the tip of their tracked branch | unset |

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

Secrets: `DOCKER_USER`, `DOCKER_PAT` (see the table above for when they are needed), and
`PRIVATE_TOKEN_PAT` with read access to private submodules when `SUBMODULES` is set.

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

## Observer

Each server runs its own swarm stack `observer` and serves Grafana at `https://<domain>/monitor/`
(that server only). The hub server serves Grafana at the root of its own domain and shows every server.
It also runs the single Alertmanager that every server sends its alerts to, which posts them to Telegram.
Each minute the hub pulls a summary from every server; a server it cannot reach raises
`ClientUnreachable`. With `MONITOR_HEARTBEAT_URL` (healthchecks.io) set, the hub pings it every
minute, so the hub going down is noticed too.

Dashboards: Server, Postgres connections, Locks & deadlocks, Postgres performance, Odoo (from Odoo's
own log lines), Postgres live (this server's `pg_stat_activity`), and Fleet on the hub. Alert rules
live in `observer/config/prometheus/rules/` and `observer/config/loki/rules/`; `observer/test/check.sh`
validates everything and unit-tests the connection alerts.

Per server, once:

1. Variables `MONITOR_DOMAIN` (the domain whose nginx serves `/monitor`, or the hub domain on the hub)
   and `MONITOR_HUB` (the hub domain), plus `RUNNER`, `STACK` and `MAIN_DB` if the repo still inlines them.
2. Secrets `MONITOR_PASSWORD` (Grafana `admin`) and `MONITOR_FLEET_PASSWORD` (the same on every
   server). The hub also needs secrets `MONITOR_TELEGRAM_BOT_TOKEN` (a @BotFather bot added to the
   alert group) and `MONITOR_HEARTBEAT_URL`, and variable `MONITOR_TELEGRAM_CHAT_ID` (the group's
   numeric id, `-100…` for supergroups).
3. In the compose file:
   - give Odoo `ODOO_PGAPPNAME: '{{.Service.Name}}.{{.Task.Slot}}-{pid}'`, so every Postgres connection
     names its service and worker pid;
   - start Postgres with the observer flags: `pg_stat_statements` preloaded, `reserved_connections`
     for the monitoring role, a `log_line_prefix` carrying pid and app, connection and lock-wait logging,
     and statements over 2s. Copy them from an existing client;
   - budget the connections. Odoo connects as a superuser, which may take the reserved slots too,
     so every Odoo instance on that Postgres together must stay under `max_connections - 8`, each
     counting `(workers + max_cron_threads) * db_maxconn + db_maxconn_gevent`. The clients use
     `db_maxconn = 8` and `db_maxconn_gevent = 32` (the websocket process) and set `max_connections`
     explicitly: 100 for one instance of up to 4 workers and 3 crons, more where instances share a db;
   - leave the db port's publish mode alone: switching a running db from ingress to `mode: host`
     failed on gass with "address already in use" and left the stack without a database;
   - cap container logs (`json-file`, `max-size`).
4. In the nginx `server{}` that serves Odoo: `include /etc/nginx/conf.d/monitor/*.locations;`. The hub
   needs nothing; its `server{}` is written by the action once the certificate is issued.
5. Copy `templates/observer.yml` and run it. On the hub, list the servers in `monitor/fleet.txt`:

       # client             domain                           [probe = outside check only]
       gass                 erp.gasstransport.com
       ruman                ruman.muritechnologies.com       probe

The action creates a read-only Postgres role `observer` (`pg_monitor`), with a password kept in
`$PROJECT_DIR/observer/secrets/`, and the `pg_stat_statements` extension in `MAIN_DB`. Rerunning
it applies config changes. `down` removes the stack and the nginx paths but keeps the data volumes.
