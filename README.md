# gemfire-k8s-helm

Reusable Kubernetes deployment implementation for Apache Geode sites (one release per application/environment/site).
Application settings live in `gemfire-application-config`; this repo never contains them.

**Product decision:** Apache Geode 2.0.x (free, Java 17+). Tanzu GemFire is out of scope for this demo/test platform.
**Topology:** ONE Kubernetes cluster. Primary and DR are namespaces + GemFire sites, e.g. `ecom-dev-primary` and `ecom-dev-dr`.

**Demo scope:** only `ecom/dev` is defined (see `gemfire-application-config`). New `<app>/<env>/values.yaml` folders are
detected by `scripts/detect-changes.sh` by path pattern, so adding an application needs no change here.
**Start here:** `docs/quickstart-kind.md`.

## How a site is deployed

```bash
scripts/generate-site-identity.sh ../gemfire-application-config/ecom/dev/values.yaml dr generated/dr-site-identity.yaml
scripts/render-helm.sh charts/gemfire-base ../gemfire-application-config/ecom/dev/values.yaml \
    generated/dr-site-identity.yaml <image-repo> sha256:<digest> out/ecom-dev-dr
```

The deploy step (Phase 3b) runs `helm upgrade --install ecom-dev-dr charts/gemfire-base -n ecom-dev-dr -f <shared config> -f <identity>`.
Primary uses the same shared file at the same commit; only the identity file differs and may contain only the key `site:`.
ds-id = ENV x 10 + SITE (prod/primary 11, prod/dr 12, dev/primary 21, dev/dr 22) from `environments/registry.yaml`.

## Key design choices

| Choice | Why |
|---|---|
| Regions, disk store, PDX, WAN sender/receiver, indexes declared in `cache.xml`, cluster configuration disabled | Declarative, identical on every member, no drift from Git; config change rolls pods |
| `cache.xml` has no site-specific value (`${wan.remote.ds.id}`, `${member.hostname}` injected at runtime) | Its checksum proves Primary == DR (`scripts/render-helm.sh`) |
| One image for locator and server, pinned by digest, built from the Apache tarball + SHA-256 | No invented images or tags |
| Servers `podManagementPolicy: Parallel`, PVC retention `Retain`, PDB `maxUnavailable: 1` | Persistent members recover together; data never deleted implicitly |
| Per-environment CA issuer (`gemfire-<env>-ca`) + NetworkPolicy limited to partner namespace | Cross-environment WAN wiring fails at TLS and network layers |
| Secrets referenced by name, values read from mounted files into an in-memory properties file | Nothing secret in Git, env vars or command lines |

## Status by file

Legend: **Executed** = actually run in the authoring sandbox; **Unverified** = written but never run (needs helm, yq, Docker or a cluster, none of which the sandbox had).

| File / component | State |
|---|---|
| `scripts/detect-changes.sh` + `tests/configuration/test-detect-changes.sh` | **Executed**: 8 checks pass (modify, new folder, unrelated file, two files, delete, rename, misnamed file, first push) |
| `scripts/generate-site-identity.sh`, `tests/configuration/test-site-identity.sh` | Written in bash + yq. `bash -n` only. **Unverified** (an earlier Python version of the same logic passed its tests; this rewrite has not been run) |
| `scripts/render-helm.sh`, `tests/helm/test-render.sh` | `bash -n` only. **Unverified** |
| `charts/gemfire-base/*` | Brace balance and JSON schema parse checked. **Never rendered by Helm** |
| `image/Dockerfile`, `image/entrypoint.sh` | `bash -n` only. **Not built** |
| `docs/quickstart-kind.md` | **Not run** |
| `charts/gemfire-monitoring`, `charts/gemfire-toolbox`, `pipelines/*`, deploy/verify/rollback scripts, remaining docs | **Not generated yet** |

Tools used by the scripts: bash, git, yq (mikefarah v4), helm. No Python.

## Known risks to resolve at first real run

1. `cache.xml` element order, `key-index` attribute and `${...}` placeholder substitution: validate with the XSD shipped in the Geode jars and a real server start.
2. Java 17 `--add-opens` flags are scraped from the distribution's `bin/gfsh` at image build; confirm the extracted list is non-empty and sufficient.
3. Demo security (`ExampleSecurityManager`, `security.json` on the classpath) is not production-grade; replace with a real SecurityManager.
4. Whether GemFire MBeans are visible to the JMX exporter on servers (not only locators) decides the metric design in Phase 3c.
5. `LocatorLauncher`/`ServerLauncher start` staying in the foreground as PID 1.
