# Cluster Documentation

This repository defines a Kubernetes homelab cluster. All infrastructure is declared as code using
[Grafana Tanka](https://tanka.dev/) (Jsonnet), with Helm charts vendored into
the repo and rendered to static manifests that [ArgoCD](https://argo-cd.readthedocs.io/)
syncs to the cluster.

## Table of Contents

- [Development Environment](#development-environment)
- [Repository Layout](#repository-layout)
- [Toolchain Overview](#toolchain-overview)
- [Workflow: From Code to Cluster](#workflow-from-code-to-cluster)
- [Tanka and Jsonnet](#tanka-and-jsonnet)
- [Helm Chart Vendoring](#helm-chart-vendoring)
- [Justfile Commands](#justfile-commands)
- [Networking and Routing](#networking-and-routing)
- [Secrets Management](#secrets-management)
- [Cluster Utilities](#cluster-utilities)
- [Observability Stack](#observability-stack)
- [Application Services](#application-services)
- [Dependency Automation (Renovate)](#dependency-automation-renovate)

---

## Development Environment

The repo is bootstrapped with [Nix Flakes](https://nixos.wiki/wiki/Flakes).
Running `nix develop` drops you into a shell with every tool needed:

| Category | Tools |
|---|---|
| Kubernetes | `kubectl`, `kubernetes-helm`, `kustomize`, `k9s` |
| Jsonnet | `jsonnet`, `go-jsonnet`, `jsonnet-bundler` (jb) |
| IaC | `tanka` (tk) |
| Utilities | `jq`, `yq-go`, `just`, `renovate` |
| Secrets | `sops`, `age`, `kubeseal`, `gitleaks` |

No global installs are required; the flake pins nixpkgs to ensure reproducibility.

---

## Repository Layout

```
.
├── flake.nix                       # Nix dev shell definition
├── Justfile                        # Task runner commands
├── chartfile.yaml                  # Helm chart dependency declarations
├── jsonnetfile.json                # Jsonnet library dependencies (jb)
├── renovate.jsonnet                # Template that generates renovate.json
├── .sops.yaml                      # SOPS encryption rules (age key)
├── .gitleaks.toml                  # Secret-scanning config
│
├── lib/
│   └── config.libsonnet            # Shared constants (IPs, etc.)
│
├── environments/
│   └── lab/
│       ├── spec.json               # Tanka environment metadata
│       ├── main.jsonnet            # All cluster resources defined here
│       └── secrets/
│           └── *.enc.yaml          # SOPS-encrypted secrets
│
├── charts/                         # Vendored Helm charts (checked into git)
│   ├── argo-cd/
│   ├── traefik/
│   ├── kube-prometheus-stack/
│   └── ...
│
├── vendor/                         # Vendored Jsonnet libraries (jb)
│   └── github.com/
│       ├── grafana/jsonnet-libs/   # tanka-util (helm.template, etc.)
│       └── jsonnet-libs/           # k8s-libsonnet v1.34
│
├── manifests/
│   └── lab/                        # Rendered YAML manifests (ArgoCD reads these)
│
├── scripts/
│   └── create-sealed-secret.sh     # Helper for creating SealedSecrets
│
└── .github/workflows/
    └── renovate.yaml               # Nightly Renovate dependency updates
```

---

## Toolchain Overview

| Tool | Role |
|---|---|
| **Tanka** | Evaluates Jsonnet, templates Helm charts, exports Kubernetes YAML |
| **Jsonnet** | Data-templating language used to compose all resources |
| **Helm** | Charts are vendored and templated via Tanka's `helm.template()` — Helm is not used as a release manager |
| **ArgoCD** | Watches `manifests/lab/` in this repo and syncs to the cluster |
| **SOPS + age** | Encrypts secrets at rest in git; decrypted in-cluster by sops-secrets-operator |
| **Sealed Secrets** | Alternative secrets path using kubeseal + cluster-side controller |
| **Renovate** | Automated PRs for chart and dependency version bumps |
| **Just** | Task runner for rendering, diffing, and maintenance commands |

---

## Workflow: From Code to Cluster

```
 Edit main.jsonnet
        │
        ▼
 just render-lab          Tanka evaluates Jsonnet, templates Helm charts,
        │                 writes YAML to manifests/lab/
        ▼
 git commit & push        Rendered manifests committed to repo
        │
        ▼
 ArgoCD detects drift     Watches manifests/lab/ on HEAD
        │
        ▼
 Cluster state updated    selfHeal: true auto-syncs on drift
```

ArgoCD is configured with:
- **selfHeal: true** — automatically reconciles when cluster state drifts from git.
- **prune: false** — does not auto-delete resources removed from git (safety measure).
- **ServerSideApply: true** — uses server-side apply for conflict resolution.
- Source: `https://github.com/ftzm/cluster.git`, path `manifests/lab`.

---

## Tanka and Jsonnet

### Environment structure

There is a single Tanka environment: `environments/lab/`.

- **`spec.json`** — tells Tanka this is an environment (no hardcoded API server; uses current kubectl context).
- **`main.jsonnet`** — the single source of truth for the entire cluster. Every resource (Helm-templated or hand-written) is defined here.

### How it works

The top-level Jsonnet object is a map of logical groups (e.g. `traefik`, `monitoring`, `blocky`). Each group typically contains:

1. A `namespace` (created via `k.core.v1.namespace.new(...)`)
2. Helm-templated `resources` via `helm.template(name, chartPath, { values: ... })`
3. Custom Kubernetes objects written directly with `k8s-libsonnet`

A `withNamespace(resources, ns)` helper automatically adds namespace metadata to all namespaced resources from Helm output, while preserving explicit namespaces and skipping cluster-scoped kinds.

### Shared config

`lib/config.libsonnet` provides shared constants:

```jsonnet
{
  nasIP: '192.168.1.3',
  publicIP: '192.168.1.4',
  tailscaleIP: '100.64.0.2',
}
```

### Vendored Jsonnet libraries

Managed by `jsonnet-bundler` (`jb install` / `jb update`):

- **`k8s-libsonnet` v1.34** — typed Kubernetes object constructors (`k.core.v1.*`, `k.apps.v1.*`, etc.)
- **`tanka-util`** — `helm.template()` for rendering Helm charts inside Jsonnet

---

## Helm Chart Vendoring

Charts are declared in `chartfile.yaml` and vendored into `charts/` using
`tk tool charts vendor`. The full chart source is checked into git so that:

- Builds are fully reproducible and offline-capable.
- The exact chart version used is always visible in the repo.
- Tanka can template charts locally without a Helm repo connection.

### Current charts

| Chart | Version | Purpose |
|---|---|---|
| nfs-subdir-external-provisioner | 4.0.18 | Dynamic NFS storage provisioning |
| traefik | 39.0.0 | Ingress controller |
| argo-cd | 9.4.1 | GitOps continuous delivery |
| kube-prometheus-stack | 81.6.2 | Prometheus, Grafana, Alertmanager |
| loki | 6.53.0 | Log aggregation |
| tempo | 1.26.1 | Distributed tracing |
| alloy | 1.6.0 | Observability collector (logs + traces) |
| sealed-secrets | 2.18.0 | Encrypted secrets controller |
| cert-manager | 1.17.2 | TLS certificate automation |
| sops-secrets-operator | 0.25.3 | SOPS/age secret decryption |

Charts are templated in Jsonnet like this:

```jsonnet
helm.template('traefik', '../../charts/traefik', {
  namespace: 'traefik',
  values: { ... },
})
```

---

## Justfile Commands

| Command | Description |
|---|---|
| `just render-lab` | Delete old manifests, run `tk export` to regenerate YAML, copy encrypted secrets |
| `just render-all` | Alias for `render-lab` (scales to multiple environments) |
| `just diff-lab` | Show what would change if applied (`tk diff`) |
| `just jb-install` | Install vendored Jsonnet dependencies |
| `just jb-update` | Update Jsonnet dependencies to latest |
| `just generate-renovate` | Regenerate `renovate.json` from the Jsonnet template + validate |
| `just test-renovate` | Dry-run Renovate locally |

The render step produces flat YAML files named `{name}-{kind}.yaml` under
`manifests/lab/`, which is the directory ArgoCD watches.

---

## Networking and Routing

### Dual-network architecture

Traefik runs with `hostNetwork: true` on the `nuc` node and binds to two
separate IPs, creating isolated public and private ingress paths:

| Network | IP | Entrypoints | Ports | Use case |
|---|---|---|---|---|
| **Public (LAN)** | `192.168.1.4` | `web`, `websecure` | 9080, 9443 | Internet-routable services |
| **Private (Tailscale)** | `100.64.0.2` | `privateweb`, `privatesecure` | 80, 443 | Internal-only access via Tailscale VPN |

### How routing decisions work

- **Traefik IngressRoute CRD** is used for all services (not standard Ingress).
- Each IngressRoute specifies which `entryPoints` it listens on.
- Setting `entryPoints: ['privateweb', 'privatesecure']` makes a service reachable only over Tailscale.
- To expose a service publicly, add `web` and `websecure` to the entrypoints list.

Currently **all services are private-only** (Tailscale).

### DNS

**Blocky** runs as a DNS proxy on the Tailscale IP (`100.64.0.2:53`):

- Maps `lan.ftzmlab.xyz` → `100.64.0.2` (Tailscale IP) so all `*.lan.ftzmlab.xyz` subdomains resolve correctly for VPN clients.
- Forwards `cluster.local` → `10.96.0.10` (CoreDNS) for in-cluster resolution.
- Provides ad-blocking via deny lists (StevenBlack, AdguardDNS, Firebog).

### TLS

- **cert-manager** obtains a wildcard certificate for `*.lan.ftzmlab.xyz` from Let's Encrypt using DNS-01 validation via the Cloudflare API.
- The wildcard cert is stored in the `traefik` namespace and set as the Traefik default TLS certificate via a `TLSStore` resource.
- All HTTPS IngressRoutes automatically use this wildcard cert.

### Service hostnames

| Hostname | Service |
|---|---|
| `hello.lan.ftzmlab.xyz` | Hello World test app |
| `argo.lan.ftzmlab.xyz` | ArgoCD (TLS passthrough) |
| `grafana.lan.ftzmlab.xyz` | Grafana dashboards |
| `ntfy.lan.ftzmlab.xyz` | Push notification service |

---

## Secrets Management

Two complementary systems are available:

### SOPS + age

Used for secrets that need to be stored as encrypted files in git.

- `.sops.yaml` configures encryption rules: files matching `*.enc.yaml` have their `data` and `stringData` fields encrypted with an age public key.
- Encrypted files live in `environments/lab/secrets/` and are copied to `manifests/lab/` during rendering.
- The **sops-secrets-operator** runs in-cluster, mounts the age private key, and decrypts `SopsSecret` CRDs into regular Kubernetes Secrets.

Currently used for: Cloudflare API token (cert-manager DNS validation).

### Sealed Secrets

Used for secrets created interactively.

- `scripts/create-sealed-secret.sh` takes key-value pairs, creates a dry-run Secret, encrypts it with `kubeseal`, and outputs Jsonnet-ready `SealedSecret` resources.
- The **sealed-secrets controller** runs in-cluster and decrypts `SealedSecret` CRDs.

Currently used for: Grafana admin credentials.

### Secret scanning

`gitleaks` is configured (`.gitleaks.toml`) to detect accidentally committed secrets, with allowlists for chart test fixtures.

---

## Cluster Utilities

### Storage — NFS Subdir External Provisioner

- Connects to a NAS at `192.168.1.3:/pool-1/k8s`.
- Creates a default `StorageClass` named `nfs`.
- All PersistentVolumeClaims in the cluster (Prometheus, Loki, Tempo, Grafana, ntfy) are dynamically provisioned here.

### Ingress — Traefik v3

- Dual-network reverse proxy (see [Networking and Routing](#networking-and-routing)).
- Exports JSON access logs (collected by Alloy → Loki).
- Prometheus metrics on port 9091 (avoids conflict with node-exporter on 9100).
- Monitored via a `PodMonitor`.

### GitOps — ArgoCD

- Watches `manifests/lab/` in this repo.
- Auto-heals drift; does not auto-prune (safe deletion requires manual action).
- Accessible at `argo.lan.ftzmlab.xyz` via TLS passthrough.

### Certificate Automation — cert-manager

- `ClusterIssuer` named `letsencrypt` using ACME DNS-01 with Cloudflare.
- Wildcard `Certificate` for `*.lan.ftzmlab.xyz` stored in the `traefik` namespace.

### DNS — Blocky

- Ad-blocking DNS proxy bound to the Tailscale IP.
- Custom DNS mapping for `lan.ftzmlab.xyz` domain.
- Conditional forwarding for `cluster.local` to CoreDNS.

---

## Observability Stack

All observability components live in the `monitoring` namespace.

### Prometheus (via kube-prometheus-stack)

- 20Gi NFS-backed storage, 30-day retention (18GB size limit).
- Discovers all `ServiceMonitor` and `PodMonitor` resources cluster-wide (not restricted by Helm release labels).
- Disabled components not relevant to homelab: etcd, kube-controller-manager, kube-scheduler, kube-proxy.

### Grafana

- Admin credentials via SealedSecret.
- Persistent storage (1Gi NFS).
- Pre-configured datasources: Prometheus (built-in), Loki, Tempo.
- Dashboard auto-discovery from all namespaces.
- Accessible at `grafana.lan.ftzmlab.xyz`.

### Alertmanager

- Routes all alerts to **ntfy** (self-hosted push notifications) via webhook.
- Watchdog alerts silenced.
- Inhibition rules suppress lower-severity alerts when higher-severity ones fire.

### Loki — Log Aggregation

- Runs in SingleBinary (monolithic) mode.
- Filesystem-backed TSDB storage, 20Gi NFS volume.
- 30-day retention with compactor-based cleanup.
- Gateway enabled for API access.

### Tempo — Distributed Tracing

- Accepts traces via OTLP (gRPC on 4317, HTTP on 4318).
- 14-day retention, 10Gi NFS volume.

### Alloy — Unified Collector

- Deployed as a DaemonSet on every node.
- **Log collection:** Discovers all pods via the Kubernetes API, collects container logs, parses JSON fields (level, msg), normalizes log levels, and pushes to Loki.
- **Trace forwarding:** Runs an OTLP receiver (gRPC + HTTP), batches traces, and exports to Tempo.
- Relabeling extracts `namespace`, `pod`, `container`, `node`, and `app` labels.

---

## Application Services

### ntfy — Push Notifications

- Self-hosted notification server (`binwiederhier/ntfy`).
- Receives webhook alerts from Alertmanager.
- 1Gi NFS-backed cache with 12h history.
- Accessible at `ntfy.lan.ftzmlab.xyz`.

### Hello World — Test App

- Minimal nginx deployment used to verify ingress and DNS are working.
- Private-only IngressRoute at `hello.lan.ftzmlab.xyz`.

### Storage Test

- A busybox pod that mounts an NFS PVC and writes a timestamp, verifying that dynamic provisioning works.

---

## Dependency Automation (Renovate)

Renovate runs daily at 04:00 UTC via GitHub Actions (`.github/workflows/renovate.yaml`).

### How it works

1. `renovate.jsonnet` reads `chartfile.yaml` and generates a `renovate.json` config with a custom regex manager per Helm chart.
2. Renovate detects version bumps in chart registries.
3. When a new version is found, it creates a PR that:
   - Updates the version in `chartfile.yaml`.
   - Runs post-upgrade tasks: `tk tool charts vendor --prune` and `just render-lab`.
   - Commits the updated chart source and re-rendered manifests.
4. The GitHub Actions workflow installs Nix to get all required tools.

### Managed dependency types

- Helm chart versions (`chartfile.yaml`)
- GitHub Actions versions (`.github/workflows/`)
- Jsonnet bundler dependencies (`jsonnetfile.json`)
