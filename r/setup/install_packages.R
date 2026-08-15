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
# Self-healing additions:
#   - every install is verified (the package must appear in the library or
#     the attempt is retried), so mirror rate-limit warnings (HTTP 429) can
#     no longer masquerade as success;
#   - a dependency-closure pass (tools::package_dependencies) installs
#     Imports/Depends/LinkingTo that the manifest does not list (ape, png,
#     UCSC.utils, ...), in rounds until the closure is complete;
#   - annotation data packages (GO.db, GenomeInfoDbData, ...) install from
#     their own source tarballs (repos = NULL), which avoids the
#     install.packages parallel-make path that fails without Rtools.
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

# --- shared helpers --------------------------------------------------------
installed_pkgs <- function() rownames(installed.packages())

# Verified retry: success only counts when the packages really appear in the
# library, because install.packages() reports mirror rate-limits (HTTP 429)
# as mere warnings and returns success with missing packages.
install_retry <- function(fun, what, attempts = 3, sleep = 3) {
  for (attempt in 1:attempts) {
    cat("Attempt", attempt, "installing", what, "\n")
    res <- tryCatch({ fun(); TRUE }, error = function(e) {
      cat("  attempt", attempt, "failed:", conditionMessage(e), "\n")
      FALSE
    })
    if (res) return(TRUE)
    Sys.sleep(sleep)
  }
  FALSE
}

# Stop unless every package is present; call inside install_retry callbacks.
ensure_installed <- function(pkgs) {
  missing <- setdiff(pkgs, installed_pkgs())
  if (length(missing) > 0) {
    stop("did not appear in the library: ", paste(missing, collapse = " "))
  }
}

# Install one annotation data package from its own source tarball
# (repos = NULL: pure data, no compilation, no parallel-make).
install_annotation_tarball <- function(pkg, ap_ann, ann_repo) {
  ver <- ap_ann[pkg, "Version"]
  url <- paste0(ann_repo, "/src/contrib/", pkg, "_", ver, ".tar.gz")
  tgz <- tempfile(fileext = ".tar.gz")
  download.file(url, tgz, mode = "wb", quiet = TRUE)
  install.packages(tgz, repos = NULL, type = "source")
  ensure_installed(pkg)
}

# --- repository selection --------------------------------------------------
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

ann_repo <- paste0(m$repos$bioc, "/packages/", m$biocVersion, "/data/annotation")
soft_repo <- paste0(m$repos$bioc, "/packages/", m$biocVersion, "/bioc")

options(repos = c(
  CRAN      = cran_repo,
  BioCsoft  = soft_repo,
  BioCann   = ann_repo,
  BioCexp   = paste0(m$repos$bioc, "/packages/", m$biocVersion, "/data/experiment")
))
options(BioC_mirror = m$repos$bioc)
options(Ncpus = 2)
options(timeout = 600)
if (!is_linux) options(pkgType = "binary")  # Windows/macOS prefer binary zips

# Source indexes exist for every repo (the mirror has no BioCann binary
# index); dependency metadata is type-independent. One shared index serves
# both the Bioc closure pass and the final whole-manifest audit.
db <- tryCatch(
  available.packages(
    repos = c(CRAN = cran_repo, BioCsoft = soft_repo, BioCann = ann_repo),
    type = "source", quiet = TRUE),
  error = function(e) NULL
)
ap_ann <- tryCatch(
  available.packages(repos = c(BioCann = ann_repo), type = "source", quiet = TRUE),
  error = function(e) NULL
)
ann_only <- if (!is.null(ap_ann)) rownames(ap_ann) else character(0)

if (!requireNamespace("BiocManager", quietly = TRUE)) {
  # Bootstrap BiocManager with retries; if the (Linux) binary repo is up but
  # its blob host is flaky, fall back to the configured source mirror.
  ok <- install_retry(function() {
    install.packages("BiocManager", repos = c(CRAN = cran_repo))
    ensure_installed("BiocManager")
  }, "BiocManager bootstrap")
  if (!ok && !identical(cran_repo, m$repos$cran)) {
    ok <- install_retry(function() {
      install.packages("BiocManager", repos = c(CRAN = m$repos$cran))
      ensure_installed("BiocManager")
    }, "BiocManager bootstrap (source mirror)")
  }
  if (!ok) stop("BiocManager bootstrap failed; cannot proceed with Bioconductor installs")
}
library(BiocManager)

installed <- installed_pkgs()
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
  ok <- install_retry(function() {
    install.packages(missing_cran, type = cran_type)
    ensure_installed(missing_cran)
  }, "CRAN packages")
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
  ok <- install_retry(function() {
    BiocManager::install(missing_bioc, version = m$biocVersion, ask = FALSE, update = FALSE, type = bioc_type)
    ensure_installed(missing_bioc)
  }, "Bioconductor packages")
  if (!ok) cat("WARNING: some Bioconductor packages failed\n")
}

# gghalves was removed from CRAN; install 0.1.4 from the CRAN archive on the
# configured mirror (falls back to the GitHub tarball, no git/credentials).
# repos = NULL: the tarball is not in any repo index, and its dependencies
# (ggplot2, Rcpp, gtable) are already installed by the CRAN pass above.
if (!"gghalves" %in% installed_pkgs()) {
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
    ensure_installed("gghalves")
  }, "gghalves from CRAN archive")
  if (!ok) cat("WARNING: gghalves install failed\n")
}

# ggalt was archived from CRAN (PCAtools needs it for biplot encircle);
# install 0.4.0 from the CRAN archive (pure R, no compilation).
if (!"ggalt" %in% installed_pkgs()) {
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
      ensure_installed("ggalt")
    }, "ggalt from CRAN archive")
  } else {
    install_retry(function() {
      tgz <- tempfile(fileext = ".tar.gz")
      download.file(paste0(m$repos$cran, "/src/contrib/Archive/ggalt/ggalt_0.4.0.tar.gz"),
        tgz, mode = "wb", quiet = TRUE)
      remotes::install_local(tgz, dependencies = TRUE)
      ensure_installed("ggalt")
    }, "ggalt from CRAN archive")
  }
  if (!ok) cat("WARNING: ggalt install failed\n")
}

# Fallbacks for packages that failed on the first pass.
#   Windows/macOS: retry with binary-then-source (ggalt is pure R, no
#     Rtools needed; its dependencies keep installing as binaries).
#   Linux: retry against the Westlake source mirror (gcc is present).
#   Bioc: annotation data packages ship source-only on Windows but are pure
#     data, so they install from single tarballs without Rtools; the rest go
#     through BiocManager source. GO.db needs GenomeInfoDbData too.
installed <- installed_pkgs()
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
  # 1) Close the dependency set: manifest installs can miss Imports of the
  #    remaining packages (e.g. AnnotationDbi needs UCSC.utils/png) when the
  #    mirror rate-limits binaries mid-pass. Install whatever is missing from
  #    the closure as binaries first.
  closure <- if (!is.null(db)) tryCatch(
    unique(unlist(tools::package_dependencies(
      still_bioc, db = db,
      which = c("Depends", "Imports", "LinkingTo"), recursive = TRUE))),
    error = function(e) character(0)) else character(0)
  need_soft <- setdiff(c(still_bioc, closure), c(installed_pkgs(), ann_only))
  if (length(need_soft) > 0) {
    cat("Installing Bioc dependency closure (binaries):", paste(need_soft, collapse = " "), "\n")
    ok <- install_retry(function() {
      BiocManager::install(need_soft, version = m$biocVersion, ask = FALSE, update = FALSE,
        type = if (is_linux) "source" else "binary", dependencies = TRUE)
      ensure_installed(need_soft)
    }, "Bioc dependency closure")
    if (!ok) cat("WARNING: Bioc dependency closure failed\n")
  }
  # 2) Annotation data packages (GO.db, GenomeInfoDbData, ...) install from
  #    single source tarballs (see install_annotation_tarball).
  #    GO.db's lazy-load pulls in AnnotationDbi, which needs the CRAN package
  #    'png' (compiled; its binary zip is often rate-limited). Try several
  #    mirrors for the binary, then fall back to source. Mirrors are
  #    Westlake-first and TUNA-free per project policy.
  tarball_done <- character(0)
  if ("GO.db" %in% still_bioc && !"png" %in% installed_pkgs()) {
    cat("Installing png (CRAN dependency of GO.db/AnnotationDbi)\n")
    png_ok <- FALSE
    if (!is_linux) {
      png_mirrors <- unique(c(cran_repo,
        "https://mirrors.ustc.edu.cn/CRAN",
        "https://mirrors.aliyun.com/CRAN",
        "https://cloud.r-project.org"))
      for (mr in png_mirrors) {
        cat("  trying png binary from", mr, "\n")
        png_ok <- install_retry(function() {
          install.packages("png", repos = c(CRAN = mr), type = "binary")
          ensure_installed("png")
        }, "png binary", attempts = 6, sleep = 10)
        if (png_ok) break
      }
    }
    if (!png_ok) {
      # Source install compiles C code: works on Linux/macOS but NOT on
      # Windows without Rtools, so only two attempts there.
      ap_cran_src <- tryCatch(
        available.packages(repos = c(CRAN = cran_repo), type = "source", quiet = TRUE),
        error = function(e) NULL
      )
      png_ver <- if (!is.null(ap_cran_src) && "png" %in% rownames(ap_cran_src)) ap_cran_src["png", "Version"] else "0.1-9"
      png_ok <- install_retry(function() {
        tgz <- tempfile(fileext = ".tar.gz")
        download.file(paste0(m$repos$cran, "/src/contrib/png_", png_ver, ".tar.gz"), tgz, mode = "wb", quiet = TRUE)
        install.packages(tgz, repos = NULL, type = "source")
        ensure_installed("png")
      }, "png source", attempts = if (is_linux) 6 else 2, sleep = 10)
    }
    if (!png_ok) cat("WARNING: png install failed; GO.db may fail\n")
  }
  for (pkg in still_bioc) {
    if (pkg %in% ann_only) {
      ok <- install_retry(function() install_annotation_tarball(pkg, ap_ann, ann_repo),
        paste0(pkg, " from annotation source tarball"))
      if (ok) tarball_done <- c(tarball_done, pkg)
    }
  }
  rest <- setdiff(still_bioc, tarball_done)
  if (length(rest) > 0) {
    cat("Installing remaining Bioconductor packages from source:", paste(rest, collapse = " "), "\n")
    ok <- install_retry(function() BiocManager::install(rest, version = m$biocVersion, ask = FALSE, update = FALSE, type = "source", dependencies = TRUE), "Bioconductor source fallback")
    if (!ok) cat("WARNING: Bioconductor source fallback failed\n")
  }
}

# 3) Dependency audit over the whole manifest: install any Depends/Imports/
#    LinkingTo of the manifest that were missed when the mirror rate-limited
#    binaries mid-pass (e.g. ape for clusterProfiler). Runs in rounds until the
#    closure is complete or a round installs nothing new.
if (!is.null(db)) {
  for (audit_round in 1:5) {
    audit_closure <- tryCatch(unique(unlist(tools::package_dependencies(
      c(m$cran, m$bioc), db = db,
      which = c("Depends", "Imports", "LinkingTo"), recursive = TRUE))),
      error = function(e) character(0))
    audit_missing <- setdiff(audit_closure, installed_pkgs())
    if (length(audit_missing) == 0) break
    cat("Dependency audit round", audit_round, ": installing missing deps:", paste(audit_missing, collapse = " "), "\n")
    audit_ann <- intersect(audit_missing, ann_only)
    audit_soft <- setdiff(audit_missing, audit_ann)
    if (length(audit_soft) > 0) {
      ok <- install_retry(function() {
        BiocManager::install(audit_soft, version = m$biocVersion, ask = FALSE, update = FALSE,
          type = if (is_linux) "source" else "binary", dependencies = TRUE)
        ensure_installed(audit_soft)
      }, "audited dependencies")
      if (!ok) cat("WARNING: some audited dependencies failed (round", audit_round, ")\n")
    }
    for (pkg in audit_ann) {
      ok <- install_retry(function() install_annotation_tarball(pkg, ap_ann, ann_repo),
        paste0(pkg, " (audited annotation dep)"))
      if (!ok) cat("WARNING:", pkg, "audit install failed (round", audit_round, ")\n")
    }
  }
}

installed <- installed_pkgs()
still_missing <- setdiff(c(m$cran, m$bioc), installed)
cat("STILL_MISSING:", paste(still_missing, collapse = " "), "\n")
if (length(still_missing) > 0) quit(status = 2) else cat("ALL_PACKAGES_OK\n")
