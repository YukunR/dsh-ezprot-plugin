#!/usr/bin/env Rscript
# install_packages.R <manifest.json>
# Installs every manifest package missing from the managed library.
# The manifest is written by the plugin (runtime-generated) and carries:
#   cran/bioc package lists, biocVersion, repos.cran, repos.bioc and an
#   optional repos.linuxBinaryCran (Posit PPM serves pre-built Linux binaries
#   as source-format tarballs; the Westlake mirrors carry no Linux binaries).
# Platform strategy:
#   Windows/macOS: CRAN binaries -> Bioconductor binaries -> archived
#     gghalves/ggalt -> source-only fallback for annotation data packages.
#   Linux: CRAN via the binary repo (default: Posit PPM, codename detected
#     from /etc/os-release) -> Bioconductor source from the configured
#     mirror (needs gcc; rocker/r-ver images provide it) -> archived
#     gghalves/ggalt -> Westlake CRAN source fallback for the remainder.
suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    # Bootstrap from the configured mirror (cloud.r-project.org is often
    # slow or blocked inside containers).
    m0 <- tryCatch(fromJSON(commandArgs(trailingOnly = TRUE)[1]), error = function(e) NULL)
    boot_repo <- if (!is.null(m0) && nzchar(m0$repos$cran)) m0$repos$cran else "https://mirrors.westlake.edu.cn/CRAN"
    install.packages("jsonlite", repos = boot_repo)
  }
  library(jsonlite)
})
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: install_packages.R <manifest.json>")
m <- fromJSON(args[1])

is_linux <- .Platform$OS.type == "unix" && Sys.info()[["sysname"]] == "Linux"

# --- repository selection -----------------------------------------------
cran_repo <- m$repos$cran
linux_binary <- NULL
if (is_linux) {
  linux_binary <- m$repos$linuxBinaryCran
  if (is.null(linux_binary) || !nzchar(linux_binary)) {
    # Date-pinned to the Bioc 3.20 era: PPM "latest" now targets R >= 4.5.
    linux_binary <- "https://packagemanager.posit.co/cran/__linux__/jammy/2024-11-15"
  }
  # Keep the URL in sync with the container's Ubuntu codename (jammy/noble).
  codename <- tryCatch({
    line <- grep("^VERSION_CODENAME=", readLines("/etc/os-release", warn = FALSE), value = TRUE)
    if (length(line) > 0) sub("^VERSION_CODENAME=", "", line[1]) else "jammy"
  }, error = function(e) "jammy")
  linux_binary <- sub("__linux__/[a-z]+", paste0("__linux__/", codename), linux_binary)
  # Use the binary repo for CRAN only when reachable; otherwise fall back to
  # the configured source mirror.
  ok <- tryCatch({
    ap <- available.packages(repos = linux_binary, type = "source", quiet = TRUE)
    nrow(ap) > 1000
  }, error = function(e) FALSE)
  if (!ok) {
    cat("Linux binary CRAN repo unreachable, using source mirror\n")
    linux_binary <- NULL
  }
  cran_repo <- if (is.null(linux_binary)) m$repos$cran else linux_binary
}

options(repos = c(
  CRAN      = cran_repo,
  BioCsoft  = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/bioc"),
  BioCann   = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/data/annotation"),
  BioCexp   = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/data/experiment")
))
options(BioC_mirror = m$repos$bioc)
options(Ncpus = 2)
options(timeout = 600)
if (!is_linux) options(pkgType = "binary")  # Windows/macOS prefer binary zips

install_retry <- function(fun, what, attempts = 3) {
  for (attempt in 1:attempts) {
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

if (!requireNamespace("BiocManager", quietly = TRUE)) {
  # Bootstrap BiocManager with retries; if the (Linux) binary repo is up but
  # its blob host is flaky, fall back to the configured source mirror.
  ok <- install_retry(function() install.packages("BiocManager", repos = c(CRAN = cran_repo)), "BiocManager bootstrap")
  if (!ok && !identical(cran_repo, m$repos$cran)) {
    ok <- install_retry(function() install.packages("BiocManager", repos = c(CRAN = m$repos$cran)), "BiocManager bootstrap (source mirror)")
  }
  if (!ok) stop("BiocManager bootstrap failed; cannot proceed with Bioconductor installs")
}
library(BiocManager)

installed <- rownames(installed.packages())
missing_cran <- setdiff(m$cran, installed)
missing_bioc <- setdiff(m$bioc, installed)
cat("PLATFORM:", if (is_linux) "linux" else "windows/macos", "\n")
cat("CRAN_REPO:", cran_repo, "\n")
cat("MISSING_CRAN:", paste(missing_cran, collapse = " "), "\n")
cat("MISSING_BIOC:", paste(missing_bioc, collapse = " "), "\n")

# On Linux "binary" is not a valid type: the binary repo serves pre-built
# binaries as ordinary tarballs, so the default type ("source") is correct.
cran_type <- if (is_linux) "source" else "binary"
bioc_type <- if (is_linux) "source" else "binary"

if (length(missing_cran) > 0) {
  ok <- install_retry(function() install.packages(missing_cran, type = cran_type), "CRAN packages")
  if (!ok) cat("WARNING: some CRAN packages failed\n")
}

# Bioc 3.20 patch releases (2025) require BH >= 1.87.0, which postdates the
# date-pinned CRAN binary snapshot used on Linux. BH is header-only, so a
# source install from the configured CRAN mirror is instant (no compilation)
# and keeps BiocParallel/fgsea building.
if (is_linux) {
  bh_ver <- tryCatch(as.character(packageVersion("BH")), error = function(e) "")
  if (bh_ver == "" || compareVersion(bh_ver, "1.87.0") < 0) {
    cat("Refreshing BH to >= 1.87.0 (Bioc 3.20 patch requirement)\n")
    ok <- install_retry(function() install.packages("BH", repos = c(CRAN = m$repos$cran), type = "source"), "BH refresh")
    if (!ok) cat("WARNING: BH refresh failed; BiocParallel/fgsea may fail\n")
  }
}

if (length(missing_bioc) > 0) {
  ok <- install_retry(function() BiocManager::install(missing_bioc, version = m$biocVersion, ask = FALSE, update = FALSE, type = bioc_type), "Bioconductor packages")
  if (!ok) cat("WARNING: some Bioconductor packages failed\n")
}

# gghalves was removed from CRAN; install 0.1.4 from the CRAN archive on the
# configured mirror (falls back to the GitHub tarball, no git/credentials).
# repos = NULL: the tarball is not in any repo index, and its dependencies
# (ggplot2, Rcpp, gtable) are already installed by the CRAN pass above.
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
  ok <- if (is_linux) {
    # Hard dependencies that are not part of the manifest: fetch them from
    # the current CRAN repo first (KernSmooth/MASS ship with R, gtable comes
    # with ggplot2), then install the archive tarball without repo lookups.
    install_retry(function() {
      install.packages(c("ash", "extRemes", "maps", "proj4", "extrafont", "plotly"),
        repos = c(CRAN = cran_repo))
      tgz <- tempfile(fileext = ".tar.gz")
      download.file(paste0(m$repos$cran, "/src/contrib/Archive/ggalt/ggalt_0.4.0.tar.gz"),
        tgz, mode = "wb", quiet = TRUE)
      install.packages(tgz, repos = NULL, type = "source")
    }, "ggalt from CRAN archive")
  } else {
    install_retry(function() {
      tgz <- tempfile(fileext = ".tar.gz")
      download.file(paste0(m$repos$cran, "/src/contrib/Archive/ggalt/ggalt_0.4.0.tar.gz"),
        tgz, mode = "wb", quiet = TRUE)
      remotes::install_local(tgz, dependencies = TRUE)
    }, "ggalt from CRAN archive")
  }
  if (!ok) cat("WARNING: ggalt install failed\n")
}

# Fallbacks for packages that failed on the first pass.
#   Windows/macOS: retry with binary-then-source (ggalt is pure R, no
#     Rtools needed; its dependencies keep installing as binaries).
#   Linux: retry against the Westlake source mirror (gcc is present).
#   Bioc: some packages (GO.db and other annotation data) ship source only;
#     data packages compile nothing. GO.db needs GenomeInfoDbData too.
installed <- rownames(installed.packages())
still_cran <- setdiff(m$cran, installed)
still_bioc <- setdiff(m$bioc, installed)
if ("GO.db" %in% still_bioc) still_bioc <- unique(c("GenomeInfoDbData", still_bioc))
if (length(still_cran) > 0) {
  cat("Installing remaining CRAN packages:", paste(still_cran, collapse = " "), "\n")
  if (is_linux) {
    fallback <- if (identical(cran_repo, m$repos$cran)) cran_repo else m$repos$cran
    ok <- install_retry(function() install.packages(still_cran, repos = c(CRAN = fallback), dependencies = TRUE), "CRAN source fallback")
  } else {
    ok <- install_retry(function() install.packages(still_cran, type = "both", dependencies = TRUE), "CRAN binary-then-source fallback")
  }
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
