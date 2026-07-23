# Deploying to ECS Fargate (AWS Academy Learner Lab)

This is the legacy Dolibarr monolith. It shares an ALB with the modernized
`tickets-microservice` — the ALB routes `/tickets` and `/tickets/*` to that
service, everything else to this one.

## What's here

- `Dockerfile` — production PHP 8.2 + Apache image. Bakes in `htdocs/`, does
  **not** bake in the local dev `conf.php` (excluded via `.dockerignore`).
- `docker/entrypoint.sh` — regenerates `conf.php` from env vars on every
  container boot (Fargate's filesystem is ephemeral; only the RDS schema
  needs to persist, not this file).
- `htdocs/install/install.forced.php` — pre-fills/locks the install wizard's
  fields from env vars. Safe to commit: no secrets baked in, only
  `getenv()` calls. This is what makes the install unattended (see below).
- `ecs/task-definition.template.json` — Fargate task definition, `LabRole`
  for both execution and task role, health check on `/`.
- `deploy/deploy.sh` — builds, pushes to ECR, opens the RDS security group
  to the ECS service, registers the task definition, creates/updates the
  service attached to the shared ALB's `tg-dolibarr` target group.
- `.env.deploy.example` — template for deploy-time config. **`.env.deploy`
  itself is gitignored — never commit it.**

## One-time setup

1. AWS credentials configured locally (same Learner Lab session as
   tickets-microservice).
2. `cp .env.deploy.example .env.deploy` and fill in: the RDS endpoint (see
   below), `DOLI_DB_PASSWORD`, `DOLI_ADMIN_PASSWORD`, and the ALB's SG/target
   group ARN if deploying behind it.
3. RDS MySQL instance for Dolibarr — this deployment used a **dedicated**
   instance (`dolibarr-db`), separate from the tickets microservice's
   Postgres RDS, since they're different engines and meant to be
   independent per the target architecture.

## Deploy

```
./deploy/deploy.sh
```

Same shape as `tickets-microservice/deploy/deploy.sh`: builds the image
(this one takes a few minutes — compiles gd/ldap/etc PHP extensions),
pushes to ECR, wires security groups, registers the task definition, and
creates/updates the ECS service.

## The install wizard (one-time, per fresh database)

`conf.php` is regenerated on every boot, but the actual `llx_*` tables in
RDS only need to be created once, the first time this deploys against a
fresh database. Because `install.forced.php` locks every field (including
the admin login/password, sourced from `DOLI_ADMIN_LOGIN`/
`DOLI_ADMIN_PASSWORD`), the wizard needs no typed input — it's just three
POSTs in sequence. Run these once, right after the first deploy against a
new database (replace `$ALB_DNS`):

```bash
curl -X POST http://$ALB_DNS/install/step2.php \
  -d "testpost=ok" -d "action=set" \
  -d "dolibarr_main_db_character_set=utf8" -d "dolibarr_main_db_collation=utf8_unicode_ci" \
  -d "selectlang=auto"

curl -X POST http://$ALB_DNS/install/step4.php \
  -d "testpost=ok" -d "action=set" -d "dolibarrpingno=checked" -d "selectlang=auto"

curl -X POST http://$ALB_DNS/install/step5.php \
  -d "testpost=ok" -d "action=set" -d "selectlang=auto"
```

The last response should say `This installation is complete.` and confirm
the admin login was created. `force_install_lockinstall = true` means the
wizard won't run again against an already-installed database — re-running
these against a database that already has tables is a no-op error, not
destructive.

After that, log in at `http://$ALB_DNS/` with `DOLI_ADMIN_LOGIN` /
`DOLI_ADMIN_PASSWORD`, then enable the **Ticket** module under
Setup → Modules (not enabled by default on a fresh Dolibarr install —
unrelated to this deployment).

## Tickets microservice integration

`TICKETS_MICROSERVICE_URL_INTERNAL` (server-side, `TicketsMicroserviceClient`)
and `TICKETS_MICROSERVICE_URL_PUBLIC` (browser-side `fetch()` in
`ticket/card.php`/`list.php`) are both set to the bare ALB URL (e.g.
`http://tickets-platform-alb-xxxx.us-east-1.elb.amazonaws.com`, no path).
Both call sites append `/tickets` themselves, so the final request lands on
`http://$ALB_DNS/tickets`, which the ALB's path-pattern rule forwards to the
`tickets-app` service — no code changes were needed there, this integration
already existed, it just needed the right URL for this environment.

## Notes / caveats for Learner Lab

- **Separate RDS instances** — Dolibarr (MySQL, `dolibarr-db`) and the
  tickets microservice (Postgres) are intentionally isolated per the target
  architecture; not shared.
- **No HTTPS** — `force_install_mainforcehttps = false` because the shared
  ALB listener in this deployment is HTTP-only. Add an ACM cert + HTTPS
  listener before using this for anything beyond a lab demo.
- **LabRole only**, same as tickets-microservice.
- Health check uses `/` — verified to return 200 both pre- and
  post-install (pre-install it serves the login page directly instead of
  redirecting to `/install`, since a valid `conf.php` always exists here).
