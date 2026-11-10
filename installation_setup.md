# Installation and deployment guide: ECOM DEV (Primary + DR) on one Kubernetes cluster

You will end with **two logical Apache Geode sites** running in ONE local Kubernetes cluster:

```
kind cluster "gemfire-demo"  (one Docker container acting as one Kubernetes node)
├── namespace ecom-dev-dr       1 locator + 2 servers   (ds-id 22)   <== WAN ==>
└── namespace ecom-dev-primary  1 locator + 2 servers   (ds-id 21)
```

Both sites are installed from the same chart and the same config file (`ecom/dev/values.yaml`).
Time needed: about 40 minutes, most of it downloads and first start-up.

> **Honesty note:** the scripts, chart and image in this repo were written but could not be run by their author
> (no Helm, yq or Docker in the authoring sandbox). Expect to fix one or two things on the first run. Section 11 says what
> to send back when something fails.

---

## 1. Choose the machine

Everything runs on one Linux machine: a laptop, a VM you already have, or a cloud VM.

| | Minimum | Recommended |
|---|---|---|
| CPU | 4 vCPU | 4 vCPU |
| RAM | 8 GB | **16 GB** |
| Disk | 40 GB free | **80 GB** SSD |
| OS | Ubuntu 22.04 or 24.04 LTS (x86_64 or ARM64) | same |
| Network | outbound internet (downloads), no inbound ports needed except SSH | same |

Why these numbers (demo profile in `ecom/dev/values.yaml`): the two sites request about **5 GiB of memory and 1.2 CPU** in total, can
grow to **10 GiB** at their limits, and use **22 GiB** of volumes (5Gi x 2 servers + 1Gi locator, per site). Kubernetes,
Docker and the image need the rest.

Typical cloud sizes that match "4 vCPU / 16 GB": AWS `t3.xlarge` or `m6i.xlarge`, Azure `Standard_D4s_v5`, GCP `e2-standard-4`.
Any Linux machine with Docker works. On Windows or macOS, use a Linux VM or WSL2 with Docker, and give it at least 8 GB.

All commands below run as a normal user with `sudo` rights.

## 2. Install the tools

You need: **git, docker, kind, kubectl, helm, yq**.

```bash
# 2.1 basics
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git unzip

# 2.2 Docker Engine (official Docker repository)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker "$USER"
```
**Log out and back in** (or run `newgrp docker`) so `docker` works without sudo.

```bash
# 2.3 kubectl, kind, yq, helm (current releases; the commands pick x86_64 or ARM64 for you)
ARCH=$(dpkg --print-architecture)    # amd64 or arm64
curl -fsSLo kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
curl -fsSLo kind    "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}"
curl -fsSLo yq      "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}"
sudo install -m 0755 kubectl kind yq /usr/local/bin/ && rm kubectl kind yq
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Check:** every line must say `ok`.
```bash
for t in git docker kind kubectl helm yq; do command -v $t >/dev/null && echo "ok      $t" || echo "MISSING $t"; done
docker run --rm hello-world | head -3      # proves docker works without sudo
yq --version                                # must say "mikefarah ... version v4"
```
Write down `kind version`, `kubectl version --client`, `helm version --short` and `yq --version`; send them if you ask for help.

## 3. Get the two repositories

Put both folders side by side (the scripts expect that):
```bash
mkdir -p ~/work && cd ~/work
# Option A: from the zip files you downloaded (upload them to the machine first)
unzip gemfire-application-config.zip
unzip gemfire-k8s-helm.zip
# Option B: from your Git server, if you pushed them
#   git clone <url>/gemfire-application-config.git && git clone <url>/gemfire-k8s-helm.git
ls ~/work        # gemfire-application-config  gemfire-k8s-helm
cd ~/work/gemfire-k8s-helm
chmod +x scripts/*.sh tests/*/*.sh image/entrypoint.sh     # zip files can lose the executable bit
```

Optional, 5 seconds, no cluster needed. This should print `PASS: 8 checks`:
```bash
tests/configuration/test-detect-changes.sh
```

## 4. Create the Kubernetes cluster

```bash
kind create cluster --name gemfire-demo
kubectl cluster-info --context kind-gemfire-demo
kubectl get nodes          # one node, STATUS Ready
```

Create the storage class the config asks for (`gemfire-storage`). kind's default provisioner is `rancher.io/local-path`:
```bash
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gemfire-storage }
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
YAML
kubectl get storageclass
```

## 5. Build the Geode image

The chart needs one image used for both locators and servers. It is built from the **official Apache tarball**, which you verify yourself.

### 5.1 Download and verify Geode 2.0.1
```bash
mkdir -p ~/work/downloads && cd ~/work/downloads
BASE=https://archive.apache.org/dist/geode/2.0.1
curl -fLO $BASE/apache-geode-2.0.1.tgz
curl -fLO $BASE/apache-geode-2.0.1.tgz.sha256      # if this 404s, open the folder in a browser and look at the file names
sha256sum apache-geode-2.0.1.tgz
cat apache-geode-2.0.1.tgz.sha256                  # the two hashes must be identical
```
If the version folder moved, browse `https://downloads.apache.org/geode/` and `https://archive.apache.org/dist/geode/`.
Stop if the hashes differ.

The Dockerfile downloads the same file again during the build and re-checks it against the hash you pass in, so the image
contains exactly what you verified.

### 5.2 Pick a Java 17 base image and pin it
Geode 2.0 needs Java 17 or newer.
```bash
docker pull eclipse-temurin:17-jre-jammy
BASE_IMAGE=$(docker inspect --format='{{index .RepoDigests 0}}' eclipse-temurin:17-jre-jammy)
echo "$BASE_IMAGE"       # looks like eclipse-temurin@sha256:<64 hex>
```

### 5.3 Build and load into kind
```bash
cd ~/work/gemfire-k8s-helm
GEODE_SHA256=$(sha256sum ~/work/downloads/apache-geode-2.0.1.tgz | cut -d' ' -f1)
docker build -t geode-member:2.0.1 \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg GEODE_VERSION=2.0.1 \
  --build-arg GEODE_SHA256="$GEODE_SHA256" \
  image/
kind load docker-image geode-member:2.0.1 --name gemfire-demo
docker exec gemfire-demo-control-plane crictl images | grep geode-member    # the image is inside the cluster node
```
Expected: the build ends with `naming to docker.io/library/geode-member:2.0.1`.

## 6. Deploy DR first, then Primary (same config file)

This is the order the real pipeline will use too: DR, check it, then Primary.

```bash
cd ~/work/gemfire-k8s-helm
CFG=../gemfire-application-config/ecom/dev/values.yaml
```

### 6.1 DR site
```bash
scripts/generate-site-identity.sh $CFG dr /tmp/ecom-dev-dr-id.yaml
cat /tmp/ecom-dev-dr-id.yaml      # look: distributedSystemId 22, partner = ecom-dev-primary (21)

helm upgrade --install ecom-dev-dr charts/gemfire-base -n ecom-dev-dr --create-namespace \
  -f $CFG -f /tmp/ecom-dev-dr-id.yaml \
  --set image.repository=geode-member --set image.tag=2.0.1 --set image.pullPolicy=Never \
  --set security.enabled=false \
  --wait --timeout 10m
kubectl get pods -n ecom-dev-dr
```
Expected within a few minutes: `ecom-dev-dr-locator-0` and `ecom-dev-dr-server-0/1` all `Running` and `1/2` or `2/2` Ready
(`2/2` = main container + log-tail sidecar). The DR logs may warn that the remote locator (Primary) is unreachable. That is
normal until Primary exists.

Why `security.enabled=false`: the chart's TLS/authentication needs certificates and secrets that are out of scope for a first
local run. Never use this flag outside a laptop demo.

### 6.2 Primary site
```bash
scripts/generate-site-identity.sh $CFG primary /tmp/ecom-dev-primary-id.yaml
helm upgrade --install ecom-dev-primary charts/gemfire-base -n ecom-dev-primary --create-namespace \
  -f $CFG -f /tmp/ecom-dev-primary-id.yaml \
  --set image.repository=geode-member --set image.tag=2.0.1 --set image.pullPolicy=Never \
  --set security.enabled=false \
  --wait --timeout 10m
kubectl get pods -A | grep ecom-dev
```
Expected: 3 pods in each of the two namespaces, all Running.

## 7. Verify

```bash
G='env HOME=/tmp /opt/geode/bin/gfsh'

# members and regions in DR
kubectl exec -n ecom-dev-dr ecom-dev-dr-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "list members" -e "list regions" -e "list gateways"
```
Expected: 1 locator + 2 servers listed, regions `CUSTOMER` and `ORDER`, and a gateway sender `ecom-dev-wan` plus a receiver on each server.

### 7.1 Replication in both directions
```bash
# DR -> Primary
kubectl exec -n ecom-dev-dr ecom-dev-dr-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "put --region=/CUSTOMER --key=k1 --value=from-dr"
sleep 5
kubectl exec -n ecom-dev-primary ecom-dev-primary-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "get --region=/CUSTOMER --key=k1"     # expect: from-dr

# Primary -> DR
kubectl exec -n ecom-dev-primary ecom-dev-primary-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "put --region=/CUSTOMER --key=k2 --value=from-primary"
sleep 5
kubectl exec -n ecom-dev-dr ecom-dev-dr-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "get --region=/CUSTOMER --key=k2"     # expect: from-primary
```
Note: entries in `CUSTOMER` expire after 3600 seconds (the TTL in the config), so test within the hour.

## 8. Change the shared config and redeploy (DR first)

Example: change `memberCount: 2` to `3` in `../gemfire-application-config/ecom/dev/values.yaml`, then repeat 6.1 (DR), check, then 6.2 (Primary).
Use the same `$CFG` file for both. Only the generated identity file differs. Redundant copies need at least 2 members; the
cluster must have room for the extra pod (about 1 GiB of memory requests and 5 GiB of disk).

## 9. Look at logs

```bash
kubectl logs -n ecom-dev-dr ecom-dev-dr-server-0 -c server --tail=50     # container output (startup messages)
kubectl logs -n ecom-dev-dr ecom-dev-dr-server-0 -c log-tail --tail=50   # Geode log file, tailed to stdout
kubectl describe pod -n ecom-dev-dr ecom-dev-dr-server-0 | tail -30      # events: scheduling, image, probes
```

## 10. Remove everything

```bash
helm uninstall ecom-dev-primary -n ecom-dev-primary
helm uninstall ecom-dev-dr -n ecom-dev-dr
# Volumes are KEPT by design (data safety). Delete them explicitly to start from scratch:
kubectl delete pvc --all -n ecom-dev-primary
kubectl delete pvc --all -n ecom-dev-dr
kubectl delete ns ecom-dev-primary ecom-dev-dr
# Or delete the whole cluster:
kind delete cluster --name gemfire-demo
```
If you redeploy without deleting the volumes, the servers recover the old data from disk.

## 11. When something goes wrong

| Symptom | Likely cause | What to do |
|---|---|---|
| `helm` says `set image.digest ... or ... image.tag` | missing `--set image.tag=2.0.1` | add the `--set image...` flags exactly as shown |
| `release name ... must be ...` | wrong release or namespace name | use `ecom-dev-dr` and `ecom-dev-primary` for both release and `-n` |
| Pod `Pending`, event "unbound PersistentVolumeClaims" | storage class missing | repeat step 4 (StorageClass `gemfire-storage`) |
| Pod `ErrImageNeverPull` or `ImagePullBackOff` | image not loaded into kind | repeat `kind load docker-image ...` in 5.3 |
| Pod `CrashLoopBackOff` | start-up error | `kubectl logs <pod> -c server --previous` and send it |
| Pod `OOMKilled` | memory limit too low for your machine or data | raise `resources.member.limits.memory` in the config, redeploy DR first |
| Servers never Ready | disk recovery or peers not found | wait 5 minutes, then `kubectl describe pod` and the logs |
| `list gateways` empty | WAN disabled or cache.xml problem | send the server logs |
| `yq: command not found` or `invalid expression` | wrong yq (the Python `yq`) | install mikefarah yq v4 as in step 2.3 |
| `permission denied` running a script | zip removed execute bit | `chmod +x scripts/*.sh` |

**If you are stuck, send me exactly these outputs:**
```bash
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl logs -n ecom-dev-dr ecom-dev-dr-locator-0 -c locator --tail=80
helm list -A
```
Fixing what the first real run reveals is the next work item, before any pipeline is built.

## 12. Using a cluster you already have (instead of kind)

Same steps, with these differences: (1) skip step 4's `kind create`, but create a StorageClass named `gemfire-storage` or change
`storage.storageClassName` in the config; (2) push the image to a registry the cluster can pull from and pass
`--set image.repository=<registry>/geode-member --set image.digest=sha256:<digest>` instead of the tag/pullPolicy flags
(this is also what the pipeline will do); (3) provide TLS and credential secrets before turning `security.enabled` back on
(documented in a later phase).
