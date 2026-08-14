# Optional Docker backend for ezprot-dsh-plugin.
#
# The plugin defaults to a locally managed R runtime (no admin, no Docker).
# For reproducibility or server deployments, build this image once and set
# `backend: docker` in the plugin config:
#
#   docker build -t ezprot:latest -f docker/Dockerfile .
#
# The image contains R 4.4.0 + every package from manifest/packages.json
# (Bioconductor 3.20). The plugin mounts the project directory at /workspace
# and runs the project's own run.R inside the container — the image carries
# no analysis data.
FROM rocker/r-ver:4.4.0

ENV R_LIBS=/opt/ezprot-lib
RUN mkdir -p /opt/ezprot-lib

# CRAN packages (Posit Public Package Manager precompiled binaries)
RUN R -e 'options(pkgType="binary", repos=c(CRAN="https://packagemanager.posit.co/cran/latest")); install.packages(c("BiocManager","tidyverse","ggplot2","pheatmap","cowplot","ggforce","gghalves","ggdist","ggrepel","patchwork","viridis","corrplot","ggdendro","RColorBrewer","scales","stringr","stringi","magrittr","broom","car","progress","jsonlite","digest","reshape2","multiUS","data.table","optparse"), Ncpus=4)'

# Bioconductor 3.20 packages
RUN R -e 'BiocManager::install(c("PCAtools","sva","clusterProfiler","enrichplot","DOSE","fgsea","qvalue","GO.db","AnnotationDbi"), version="3.20", ask=FALSE, update=FALSE)'

WORKDIR /workspace
