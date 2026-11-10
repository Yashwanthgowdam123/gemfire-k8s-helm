# Quickstart: ECOM DEV (DR + Primary) on a local kind cluster

Goal: see two Geode sites, `ecom-dev-dr` and `ecom-dev-primary`, running from the SAME config file,
and replicate one entry between them. Demo size: about 5 GiB of memory requests, 22 GiB of disk.
Security is turned off for this local demo (`--set security.enabled=false`); never do that outside a laptop.

**Status: written, not yet run by the author.** If a step fails, send the error output.

## 0. You need
docker, kind, kubectl, helm, yq (mikefarah v4), git, and both repos checked out side by side:
```
work/gemfire-application-config
work/gemfire-k8s-helm
```

## 1. Cluster and storage class
```bash
kind create cluster --name gemfire-demo
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gemfire-storage }
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
YAML
```

## 2. Build the image (one image for locator and server)
Download `apache-geode-2.0.1.tgz` from the official Apache Geode release page, verify it against the
checksum/signature published there, and compute `GEODE_SHA256=$(sha256sum apache-geode-2.0.1.tgz | cut -d' ' -f1)`.
Pick a JRE 17 base image and pin it by digest.
```bash
cd gemfire-k8s-helm
docker build -t geode-member:2.0.1 \
  --build-arg BASE_IMAGE=<jre17-base@sha256:...> \
  --build-arg GEODE_VERSION=2.0.1 --build-arg GEODE_SHA256=<sha256> image/
kind load docker-image geode-member:2.0.1 --name gemfire-demo
```

## 3. Deploy DR first, then Primary (same config file)
```bash
CFG=../gemfire-application-config/ecom/dev/values.yaml
for site in dr primary; do
  scripts/generate-site-identity.sh $CFG $site /tmp/ecom-dev-$site-id.yaml
  helm upgrade --install ecom-dev-$site charts/gemfire-base -n ecom-dev-$site --create-namespace \
    -f $CFG -f /tmp/ecom-dev-$site-id.yaml \
    --set image.repository=geode-member --set image.tag=2.0.1 --set image.pullPolicy=Never \
    --set security.enabled=false --wait --timeout 10m
done
kubectl get pods -A | grep ecom-dev
```
Expected: per site 1 locator pod and 2 server pods, all Running/Ready.

## 4. Replicate one entry both ways
```bash
G='env HOME=/tmp /opt/geode/bin/gfsh'
kubectl exec -n ecom-dev-dr ecom-dev-dr-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "put --region=/CUSTOMER --key=k1 --value=from-dr"
sleep 5
kubectl exec -n ecom-dev-primary ecom-dev-primary-locator-0 -c locator -- $G \
  -e "connect --locator=localhost[10334]" -e "get --region=/CUSTOMER --key=k1"
```
Expected: Primary returns `from-dr`. Repeat with the roles swapped (`k2`, `from-primary`) for the other direction.
Useful checks: `list gateways`, `describe region --name=/CUSTOMER`.

## Clean up
```bash
kind delete cluster --name gemfire-demo
```
