# syntax=docker/dockerfile:1
# Single multi-stage build. No network API calls happen here: every URL, checksum and
# digest comes from versions.json via scripts/build_args.py.
ARG BASE_IMAGE=debian:13@sha256:3cda3ca472ce45507a5109c6a3907093e24d9ae67d55954c9a07a45665dafba2
# Either the local stage below, or a published image such as
# ghcr.io/metril/unifi-protect-fwdebs:<fw-version>
ARG FWDEBS_IMAGE=fwdebs

# ---------------------------------------------------------------- firmware debs
FROM debian:trixie AS fwdebs
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked --mount=type=cache,target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget binwalk dpkg-repack squashfs-tools
ARG FW_URL
ARG FW_SHA256=""
ARG FW_SIZE=""
ARG FW_PACKAGES
COPY scripts/extract_debs.sh /usr/local/bin/extract_debs.sh
RUN FW_URL="$FW_URL" FW_SHA256="$FW_SHA256" FW_SIZE="$FW_SIZE" FW_PACKAGES="$FW_PACKAGES" \
    /usr/local/bin/extract_debs.sh

FROM ${FWDEBS_IMAGE} AS fwdebs-src

# --------------------------------------------------------------------- protect
FROM ${BASE_IMAGE} AS protect
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# inotify-tools: fix_hosts.sh; net-tools (arp): ONVIF camera adoption; e2fsprogs: chattr
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked --mount=type=cache,target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends apt-transport-https ca-certificates \
    && sed -i 's/http:/https:/g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get -y --no-install-recommends dist-upgrade \
    && apt-get -y --no-install-recommends install \
        vim adduser inotify-tools curl wget mount psmisc dpkg apt lsb-release sudo gnupg \
        dirmngr mdadm iproute2 ethtool procps cron lvm2 systemd systemd-timesyncd sysstat \
        net-tools jq e2fsprogs \
    && find /etc/systemd/system /lib/systemd/system -path '*.wants/*' \
        -not -name '*journald*' -not -name '*systemd-tmpfiles*' -not -name '*systemd-user-sessions*' \
        -exec rm {} \;

RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked --mount=type=cache,target=/var/cache/apt,sharing=locked \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian $(lsb_release -cs) nginx" \
        > /etc/apt/sources.list.d/nginx.list \
    && printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/postgresql.list \
    # PG14 goes EOL 2026-11-12 and moves to the archive repo \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] https://apt-archive.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg-archive main" \
        >> /etc/apt/sources.list.d/postgresql.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-14

COPY --from=fwdebs-src /debs /opt/debs
RUN mv /opt/debs/version /usr/lib/version

# PRODUCT_DEBS: space separated "name,url,sha256" entries from versions.json
ARG PRODUCT_DEBS
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked --mount=type=cache,target=/var/cache/apt,sharing=locked \
    systemctl enable systemd-timesyncd.service systemd-time-wait-sync.service \
    && apt-get install -y --no-install-recommends /opt/debs/ubnt-archive-keyring_*_arm64.deb \
    && echo "deb https://apt.artifacts.ui.com $(lsb_release -cs) release" > /etc/apt/sources.list.d/ubiquiti.list \
    && apt-get update \
    # install the discovery client with a stubbed systemctl (no running systemd at build time) \
    && mv /bin/systemctl /bin/systemctl.tmp \
    && printf '#!/bin/bash\necho 0\n' > /bin/systemctl && chmod +x /bin/systemctl \
    && apt-get install -y --no-install-recommends /opt/debs/uos-discovery-client_*_arm64.deb \
    && mv /bin/systemctl.tmp /bin/systemctl \
    && systemctl enable uos-discovery-client.service \
    # shared libs for /usr/bin/ms that the package does not depend on \
    && apt-get install -y --no-install-recommends libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libglib2.0-0t64 \
    && mkdir -p /opt/products \
    && for entry in $PRODUCT_DEBS; do \
        IFS=, read -r name url sha <<< "$entry"; \
        wget --no-verbose -O "/opt/products/$name.deb" "$url"; \
        if [ -n "$sha" ]; then echo "$sha  /opt/products/$name.deb" | sha256sum -c -; fi; \
    done \
    && apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        /opt/debs/*.deb /opt/products/*.deb \
    && rm -rf /opt/debs /opt/products

COPY scripts/apply_patches.sh /opt/apply_patches.sh
RUN /opt/apply_patches.sh pre
COPY files/ /
RUN /opt/apply_patches.sh post && rm /opt/apply_patches.sh

ARG IMAGE_VERSION=dev
ARG PROTECT_VERSION=unknown
ARG FW_VERSION=unknown
ARG SOURCE_SHA=unknown
RUN echo "$IMAGE_VERSION" > /etc/unifi-protect-image-version

LABEL org.opencontainers.image.title="unifi-protect" \
      org.opencontainers.image.source="https://github.com/metril/unifi-protect" \
      org.opencontainers.image.revision="${SOURCE_SHA}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      com.unifi-protect.protect-version="${PROTECT_VERSION}" \
      com.unifi-protect.firmware-version="${FW_VERSION}" \
      com.unifi-protect.uos-version="${FW_VERSION}"

VOLUME ["/srv", "/data", "/persistent"]
HEALTHCHECK --interval=60s --timeout=15s --start-period=10m --retries=3 CMD ["/usr/sbin/healthcheck.sh"]
STOPSIGNAL SIGINT
CMD ["/lib/systemd/systemd"]
