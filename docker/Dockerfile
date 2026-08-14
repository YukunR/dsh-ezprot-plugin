# ezprot compute image: R 4.4.0 + the exact plugin package manifest.
# Single source of truth: the image runs the plugin's own installer and
# runtime probe, so the image can never drift from manifest/packages.json.
# Build-time uses the Westlake mirrors; published images are pulled as-is,
# so END USERS never depend on mirror quality.
FROM rocker/r-ver:4.4.0

ENV R_LIBS=/opt/ezprot-lib \
    EZPROT_IN_IMAGE=1

COPY manifest/packages.json /opt/ezprot/manifest.json
COPY docker/manifest-runtime.json /opt/ezprot/manifest-runtime.json
COPY r/install_packages.R /opt/ezprot/install_packages.R
COPY r/check_runtime.R /opt/ezprot/check_runtime.R

# Full manifest install (CRAN binaries -> Bioc 3.20 binaries -> archived
# gghalves/ggalt -> source-only annotation data).
RUN Rscript /opt/ezprot/install_packages.R /opt/ezprot/manifest-runtime.json

# Build-time verification: the build FAILS if the runtime probe fails.
RUN Rscript /opt/ezprot/check_runtime.R /opt/ezprot/manifest-runtime.json

WORKDIR /workspace
CMD ["Rscript"]
