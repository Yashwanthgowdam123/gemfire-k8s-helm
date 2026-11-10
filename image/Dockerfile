# Apache Geode member image (locator and server share one image).
# Every input is a REQUIRED build arg with no default, so nothing floats:
#   BASE_IMAGE            JRE 17 base pinned by digest (Geode 2.0 needs Java 17)
#   GEODE_VERSION         e.g. 2.0.1
#   GEODE_SHA256          from the official Apache release checksum file (not invented here)
#   JMX_EXPORTER_VERSION / JMX_EXPORTER_SHA256   OPTIONAL Prometheus jmx_exporter java agent
# The pipeline records the pushed image DIGEST in the promotion manifest; deployments use it.
ARG BASE_IMAGE
FROM ${BASE_IMAGE} AS fetch
ARG GEODE_VERSION
ARG GEODE_SHA256
ARG JMX_EXPORTER_VERSION
ARG JMX_EXPORTER_SHA256
RUN test -n "$GEODE_VERSION" -a -n "$GEODE_SHA256" \
 && apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL -o /tmp/geode.tgz "https://archive.apache.org/dist/geode/${GEODE_VERSION}/apache-geode-${GEODE_VERSION}.tgz" \
 && echo "${GEODE_SHA256}  /tmp/geode.tgz" | sha256sum -c - \
 && mkdir -p /opt && tar -xzf /tmp/geode.tgz -C /opt && mv /opt/apache-geode-${GEODE_VERSION} /opt/geode \
 && mkdir -p /opt/jmx_exporter \
 # Optional metrics agent: only fetched when both args are given (not needed for the kind quickstart).
 && if [ -n "$JMX_EXPORTER_VERSION" ]; then \
      test -n "$JMX_EXPORTER_SHA256" \
      && curl -fsSL -o /tmp/jmx.jar "https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar" \
      && echo "${JMX_EXPORTER_SHA256}  /tmp/jmx.jar" | sha256sum -c - \
      && mv /tmp/jmx.jar /opt/jmx_exporter/jmx_prometheus_javaagent.jar; fi \
 # Java 17 module flags: take them from the distribution's own launcher so they match this
 # exact Geode version instead of being guessed here. Empty file if the script has none.
 && (grep -oE -- '--add-(opens|exports)[ =][^ "]+' /opt/geode/bin/gfsh | sed 's/ /=/' | sort -u > /opt/geode-java-opts.txt || true)

ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG GEODE_VERSION
LABEL org.opencontainers.image.title="geode-member" \
      org.opencontainers.image.version="${GEODE_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"
RUN (getent group 1000 >/dev/null || groupadd -g 1000 geode) \
 && (getent passwd 1000 >/dev/null || useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin geode) \
 && mkdir -p /data /logs /runtime && chown 1000:1000 /data /logs /runtime
COPY --from=fetch /opt/geode /opt/geode
COPY --from=fetch /opt/jmx_exporter /opt/jmx_exporter
COPY --from=fetch /opt/geode-java-opts.txt /opt/geode-java-opts.txt
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod 0555 /opt/entrypoint.sh
ENV GEODE_HOME=/opt/geode
USER 1000:1000
WORKDIR /data
ENTRYPOINT ["/opt/entrypoint.sh"]
