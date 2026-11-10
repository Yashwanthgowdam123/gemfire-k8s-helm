#!/usr/bin/env bash
# Starts a Geode locator or server in the FOREGROUND as PID 1 (exec), so SIGTERM from the
# kubelet reaches the JVM and the member departs gracefully within terminationGracePeriodSeconds.
# Secrets are read from mounted files and written to an in-memory, mode-600 properties file:
# they are never passed on a command line or through environment variables.
set -euo pipefail
role=${1:?usage: entrypoint.sh locator|server}
: "${POD_NAME:?}" "${HEADLESS_SERVICE:?}" "${POD_NAMESPACE:?}" "${CLUSTER_DOMAIN:?}"
fqdn="${POD_NAME}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"

umask 077
props=/runtime/gemfire.properties
cp "/config/gemfire-${role}.properties" "$props"
echo "log-file=/logs/${POD_NAME}.log" >> "$props"

# Java .properties treats backslash specially; escape it. Avoid newlines in secrets.
esc() { sed -e 's/\\/\\\\/g' <<<"$1"; }
if [[ "${SECURITY_ENABLED:-true}" == "true" ]]; then
  tlspw=$(esc "$(< /tls-password/password)")
  {
    echo "ssl-keystore-password=${tlspw}"
    echo "ssl-truststore-password=${tlspw}"
    echo "security-username=$(esc "$(< /credentials/username)")"
    echo "security-password=$(esc "$(< /credentials/password)")"
  } >> "$props"
fi

# Module flags extracted from this Geode version's own launcher at image build time.
extra=()
[[ -s /opt/geode-java-opts.txt ]] && mapfile -t extra < /opt/geode-java-opts.txt

# /credentials is on the classpath so the demo SecurityManager can resolve security.json.
cp="${GEODE_HOME}/lib/geode-dependencies.jar:/credentials"
common=(
  "${extra[@]}"
  "-DgemfirePropertyFile=${props}"
  "-Dmember.hostname=${fqdn}"            # cache.xml ${member.hostname}
  "-Dwan.remote.ds.id=${WAN_REMOTE_DS_ID:-0}"  # cache.xml ${wan.remote.ds.id}
  "-Djava.io.tmpdir=/tmp"
)
# shellcheck disable=SC2086  # JAVA_OPTS is intentionally word-split
case "$role" in
  locator)
    mkdir -p /data/locator
    exec java ${JAVA_OPTS:-} "${common[@]}" -cp "$cp" org.apache.geode.distributed.LocatorLauncher start "$POD_NAME" \
      --port="${LOCATOR_PORT:-10334}" --dir=/data/locator --hostname-for-clients="$fqdn"
    ;;
  server)
    mkdir -p /data/server/diskstore
    exec java ${JAVA_OPTS:-} "${common[@]}" -cp "$cp" org.apache.geode.distributed.ServerLauncher start "$POD_NAME" \
      --server-port="${SERVER_PORT:-40404}" --dir=/data/server --hostname-for-clients="$fqdn" \
      --max-connections="${MAX_CONNECTIONS:-800}" --max-threads="${MAX_THREADS:-0}" \
      --maximum-time-between-pings="${MAX_PING_MS:-60000}"
    ;;
  *) echo "unknown role: $role" >&2; exit 2 ;;
esac
