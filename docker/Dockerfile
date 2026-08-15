# ezprot compute image: R 4.4.0 + the exact plugin package manifest.
# Single source of truth: the image runs the plugin's own installer and
# runtime probe, so the image can never drift from manifest/packages.json.
# Build-time uses the Westlake mirrors (plus Posit PPM for Linux CRAN
# binaries); published images are pulled as-is, so END USERS never depend
# on mirror quality.
# R_BASE is overridable so builds behind an unreliable Docker Hub route can
# use a registry mirror, e.g.:
#   docker build --build-arg R_BASE=hub.rat.dev/rocker/r-ver:4.4.0 ...
# APT_MIRROR / APT_MIRROR_BACKUP are overridable so builds behind an
# unreliable Ubuntu archive route can use system-package mirrors, e.g.:
#   docker build --build-arg APT_MIRROR=https://mirrors.westlake.edu.cn/ubuntu \
#     --build-arg APT_MIRROR_BACKUP=https://mirror.sjtu.edu.cn/ubuntu ...
ARG R_BASE=docker.io/rocker/r-ver:4.4.0
FROM ${R_BASE}

ENV R_LIBS=/opt/ezprot-lib \
    EZPROT_IN_IMAGE=1

COPY manifest/packages.json /opt/ezprot/manifest.json
COPY docker/manifest-runtime.json /opt/ezprot/manifest-runtime.json
COPY r/setup/install_packages.R /opt/ezprot/install_packages.R
COPY r/setup/check_runtime.R /opt/ezprot/check_runtime.R

# System libraries for the R installs. r-ver is deliberately minimal: the
# Posit PPM Linux binaries link system libs at runtime (fs -> libuv1,
# proj4 -> libproj, igraph -> libglpk, gdtools -> cairo) and the Bioc source
# builds need dev headers (zlib.h for XVector, libxml2 for XML, ...).
# Networks where archive.ubuntu.com is unreachable can point apt at mirrors
# (Westlake rate-limits bursts, so a backup mirror is used as failover when
# provided):
#   docker build --build-arg APT_MIRROR=https://mirrors.westlake.edu.cn/ubuntu \
#     --build-arg APT_MIRROR_BACKUP=https://mirror.sjtu.edu.cn/ubuntu ...
ARG APT_MIRROR=
ARG APT_MIRROR_BACKUP=
RUN if [ -n "$APT_MIRROR" ]; then \
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do \
        [ -f "$f" ] || continue; \
        sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g; s|http://ports.ubuntu.com/ubuntu-ports|$APT_MIRROR|g" "$f"; \
      done; \
    fi; \
    if [ -n "$APT_MIRROR_BACKUP" ]; then \
      printf 'deb %s jammy main restricted universe multiverse\ndeb %s jammy-updates main restricted universe multiverse\ndeb %s jammy-security main restricted universe multiverse\n' "$APT_MIRROR_BACKUP" "$APT_MIRROR_BACKUP" "$APT_MIRROR_BACKUP" > /etc/apt/sources.list.d/ezprot-backup.list; \
    fi; \
    apt-get update || exit 1; \
    ok=0; \
    for i in 1 2 3 4 5; do \
      echo "apt install attempt $i"; \
      if apt-get install -y --no-install-recommends -o Acquire::Retries=3 \
          zlib1g-dev libxml2-dev libcurl4-openssl-dev libssl-dev libuv1 libproj22 \
          libglpk40 libcairo2; then \
        ok=1; break; \
      fi; \
      sleep 30; \
    done; \
    if [ "$ok" != 1 ]; then echo "apt install failed after 5 attempts"; exit 1; fi; \
    rm -rf /var/lib/apt/lists/* && apt-get clean

# Full manifest install. Linux strategy: CRAN packages come from the Posit
# PPM binary repo (the Westlake mirrors carry no Linux binaries), Bioc 3.20
# packages build from source against the Westlake Bioc mirror (gcc ships with
# r-ver), and archived gghalves/ggalt come from the Westlake CRAN archive.
RUN Rscript /opt/ezprot/install_packages.R /opt/ezprot/manifest-runtime.json

# Build-time verification: the build FAILS if the runtime probe fails.
RUN Rscript /opt/ezprot/check_runtime.R /opt/ezprot/manifest-runtime.json

WORKDIR /workspace
CMD ["Rscript"]
