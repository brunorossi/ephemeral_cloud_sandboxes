# uffizzi-floci — Documentation

Self-hosted **Uffizzi Open Source** on a **single-node K3s** cluster, delivered via
**ArgoCD** (app-of-apps), served **HTTP-only** through Traefik, with secrets managed
by **Sealed Secrets**. Developers get **one virtual cluster each** and pick a
template: **`floci-aws`** (AWS emulator) or **`floci-azure`** (Azure emulator).

## Documentation map

| Doc | What it covers |
|---|---|
| [01 — Overview](01-overview.md) | What this project is, scope, and key decisions |
| [02 — Architecture](02-architecture.md) | Components, GitOps flow, diagrams, data model |
| [03 — Prerequisites](03-prerequisites.md) | Cluster, tools, DNS, and access requirements |
| [04 — Installation](04-installation.md) | Step-by-step bootstrap of the app-of-apps |
| [05 — Configuration](05-configuration.md) | Values files, placeholders, per-environment settings |
| [06 — Secrets (Sealed Secrets)](06-secrets.md) | Creating and rotating encrypted secrets |
| [07 — Developer Guide](07-developer-guide.md) | Creating and using a personal virtual cluster |
| [08 — Operations](08-operations.md) | Day-2: sync, upgrades, scaling, promotion |
| [09 — Troubleshooting](09-troubleshooting.md) | Common failures and how to resolve them |
| [10 — Repository Reference](10-repository-reference.md) | Every file and folder explained |

## Quick links
- Project summary: [`../PROJECT.md`](../PROJECT.md)
- Repo quickstart: [`../README.md`](../README.md)
- Formal spec: [`../.kiro/specs/uffizzi-floci/`](../.kiro/specs/uffizzi-floci/)

## Conventions used in these docs
- Shell commands assume you run them from the repository root.
- Placeholders appear as `<ORG>`, `<username>`, `<node-ip>`, `<env>` and must be
  replaced with real values.
- `<env>` is one of `dev`, `staging`, `prod`.
- Everything is **HTTP** — there is no TLS anywhere by design.

## Important scope note
The Uffizzi **web Dashboard is not open source** and is **not** part of this project.
All management happens through the **Uffizzi CLI** against the self-hosted API. See
[Overview](01-overview.md#scope) for details.
