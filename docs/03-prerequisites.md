# 03 — Prerequisites

## Cluster

- **K3s**, single node, with the bundled **Traefik** ingress enabled (default).
- **ArgoCD already installed** in the cluster in its own namespace. This repo does
  not install or manage ArgoCD.
- Cluster admin access (the AppProject grants cluster-scoped resource permissions for
  installing CRDs such as `UffizziCluster` and `SealedSecret`).

Verify:
```bash
kubectl get nodes
kubectl -n kube-system get pods | grep -i traefik
kubectl get ns argocd
kubectl -n argocd get pods            # ArgoCD running
```

## Local tools

| Tool | Purpose | Notes |
|---|---|---|
| `kubectl` | Apply manifests, inspect cluster | Match your K3s version |
| `helm` | Render/inspect charts (validation) | v3 |
| `kubeseal` | Encrypt secrets into SealedSecrets | Match controller version |
| `uffizzi` CLI | Create/use virtual clusters | From UffizziCloud/uffizzi_cli |
| `argocd` CLI (optional) | Trigger/inspect syncs | Or use the ArgoCD UI |

## DNS / name resolution

Because everything is HTTP on `.local` names, each machine that talks to the API or
to an ephemeral environment must resolve those names to the node IP.

- Single developer / test box: add entries to `/etc/hosts`.
- Team setup: point a wildcard `*.dev.local` (and staging/prod) at the node via your
  local DNS resolver.

Example `/etc/hosts`:
```
<node-ip>  api.dev.local
<node-ip>  dev-<username>.dev.local
<node-ip>  floci-aws-<username>.dev.local     # if using the floci-aws emulator ingress
<node-ip>  floci-azure-<username>.dev.local   # if using the floci-azure emulator ingress
```

## Git repository

- A Git repo reachable by ArgoCD, replacing the `<ORG>` placeholder throughout.
- ArgoCD must have read access (public repo, or credentials configured in ArgoCD).

## Access checklist

- [ ] `kubectl` context points at the K3s cluster.
- [ ] ArgoCD is healthy in its namespace.
- [ ] Traefik is serving on the node.
- [ ] `kubeseal` and the `uffizzi` CLI are installed.
- [ ] `.local` hostnames resolve to the node IP.
- [ ] `<ORG>` (and other placeholders) replaced in the repo.
