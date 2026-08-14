#!/usr/bin/env Rscript
# install_packages.R <manifest.json>
# Installs every manifest package missing from the managed library.
# The manifest is written by the plugin (runtime-generated) and carries:
#   cran/bioc package lists, biocVersion, repos.cran, repos.bioc
# Strategy: CRAN binaries -> Bioconductor 3.20 binaries -> special cases
# (gghalves from the CRAN archive) -> source-only fallback for annotation
# data packages (no Rtools required).
suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    install.packages("jsonlite", repos = "https://cloud.r-project.org")
  }
  library(jsonlite)
})
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: install_packages.R <manifest.json>")
m <- fromJSON(args[1])

options(repos = c(
  CRAN      = m$repos$cran,
  BioCsoft  = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/bioc"),
  BioCann   = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/data/annotation"),
  BioCexp   = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/data/experiment")
))
options(BioC_mirror = m$repos$bioc)
options(Ncpus = 2)
options(timeout = 600)
options(pkgType = "binary")

if (!requireNamespace("BiocManager", quietly = TRUE)) {
  install.packages("BiocManager", repos = c(CRAN = m$repos$cran))
}
library(BiocManager)

installed <- rownames(installed.packages())
missing_cran <- setdiff(m$cran, installed)
missing_bioc <- setdiff(m$bioc, installed)
cat("MISSING_CRAN:", paste(missing_cran, collapse = " "), "\n")
cat("MISSING_BIOC:", paste(missing_bioc, collapse = " "), "\n")

install_retry <- function(fun, what) {
  for (attempt in 1:3) {
    cat("Attempt", attempt, "installing", what, "\n")
    res <- tryCatch({ fun(); TRUE }, error = function(e) {
      cat("  attempt", attempt, "failed:", conditionMessage(e), "\n")
      FALSE
    })
    if (res) return(TRUE)
    Sys.sleep(3)
  }
  FALSE
}

if (length(missing_cran) > 0) {
  ok <- install_retry(function() install.packages(missing_cran, type = "binary"), "CRAN packages")
  if (!ok) cat("WARNING: some CRAN packages failed\n")
}
if (length(missing_bioc) > 0) {
  ok <- install_retry(function() BiocManager::install(missing_bioc, version = m$biocVersion, ask = FALSE, update = FALSE, type = "binary"), "Bioconductor packages")
  if (!ok) cat("WARNING: some Bioconductor packages failed\n")
}

# gghalves was removed from CRAN; install 0.1.4 from the CRAN archive on the
# configured mirror (falls back to the GitHub tarball, no git/credentials).
if (!"gghalves" %in% rownames(installed.packages())) {
  cat("Installing gghalves 0.1.4 from the CRAN archive (removed from CRAN)\n")
  ok <- install_retry(function() {
    tgz <- tempfile(fileext = ".tar.gz")
    tryCatch(
      download.file(paste0(m$repos$cran, "/src/contrib/Archive/gghalves/gghalves_0.1.4.tar.gz"),
        tgz, mode = "wb", quiet = TRUE),
      error = function(e) download.file(
        "https://github.com/erocoar/gghalves/archive/refs/heads/master.tar.gz",
        tgz, mode = "wb", quiet = TRUE)
    )
    install.packages(tgz, repos = NULL, type = "source")
  }, "gghalves from CRAN archive")
  if (!ok) cat("WARNING: gghalves install failed\n")
}

# ggalt was archived from CRAN (PCAtools needs it for biplot encircle);
# install 0.4.0 from the CRAN archive (pure R, no compilation).
if (!"ggalt" %in% rownames(installed.packages())) {
  cat("Installing ggalt 0.4.0 from the CRAN archive (archived from CRAN)\n")
  ok <- install_retry(function() {
    tgz <- tempfile(fileext = ".tar.gz")
    download.file(paste0(m$repos$cran, "/src/contrib/Archive/ggalt/ggalt_0.4.0.tar.gz"),
      tgz, mode = "wb", quiet = TRUE)
    remotes::install_local(tgz, dependencies = TRUE)
  }, "ggalt from CRAN archive")
  if (!ok) cat("WARNING: ggalt install failed\n")
}

# Fallbacks for packages without Windows binaries on the first pass.
#   CRAN: retry with binary-then-source (ggalt is pure R, no Rtools needed;
#         its dependencies keep installing as binaries).
#   Bioc: some packages (GO.db and other annotation data) ship source only;
#         data packages compile nothing. GO.db needs GenomeInfoDbData too.
installed <- rownames(installed.packages())
still_cran <- setdiff(m$cran, installed)
still_bioc <- setdiff(m$bioc, installed)
if ("GO.db" %in% still_bioc) still_bioc <- unique(c("GenomeInfoDbData", still_bioc))
if (length(still_cran) > 0) {
  cat("Installing remaining CRAN packages (binary then source):", paste(still_cran, collapse = " "), "\n")
  ok <- install_retry(function() install.packages(still_cran, type = "both", dependencies = TRUE), "CRAN binary-then-source fallback")
  if (!ok) cat("WARNING: CRAN fallback failed\n")
}
if (length(still_bioc) > 0) {
  cat("Installing remaining Bioconductor packages from source:", paste(still_bioc, collapse = " "), "\n")
  ok <- install_retry(function() BiocManager::install(still_bioc, version = m$biocVersion, ask = FALSE, update = FALSE, type = "source", dependencies = TRUE), "Bioconductor source fallback")
  if (!ok) cat("WARNING: Bioconductor source fallback failed\n")
}

installed <- rownames(installed.packages())
still_missing <- setdiff(c(m$cran, m$bioc), installed)
cat("STILL_MISSING:", paste(still_missing, collapse = " "), "\n")
if (length(still_missing) > 0) quit(status = 2) else cat("ALL_PACKAGES_OK\n")
