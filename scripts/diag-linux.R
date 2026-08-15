#!/usr/bin/env Rscript
# Verify a date-pinned PPM binary snapshot works with R 4.4.0 / Bioc 3.20.
# Run: docker run --rm -v <repo>/scripts:/diag <R_BASE> Rscript /diag/diag-linux.R
snap <- "https://packagemanager.posit.co/cran/__linux__/jammy/2024-11-15"
cat("R:", R.version.string, "\n")
want <- c("ggplot2", "dplyr", "tidyverse", "car", "Deriv", "doBy", "pbkrtest",
          "lme4", "Rcpp", "readxl", "remotes", "BiocManager", "multiUS",
          "ggforce", "ggdist", "patchwork", "data.table", "stringi")
ap <- tryCatch(available.packages(repos = snap, type = "source", quiet = TRUE),
  error = function(e) { cat("ERROR:", conditionMessage(e), "\n"); NULL })
if (!is.null(ap)) {
  cat("OK n=", nrow(ap), "\n", sep = "")
  for (p in intersect(want, rownames(ap))) cat("  ", p, " ", ap[p, "Version"], "\n", sep = "")
}

# Decisive test: install the two packages that failed before, as binaries.
lib <- tempfile("lib")
dir.create(lib)
ok <- tryCatch({
  install.packages(c("Deriv", "car"), repos = snap, lib = lib, type = "source", quiet = TRUE)
  rownames(installed.packages(lib.loc = lib))
}, error = function(e) { cat("install ERROR:", conditionMessage(e), "\n"); character(0) })
cat("installed:", paste(ok, collapse = " "), "\n")
cat("Deriv ok:", "Deriv" %in% ok, " car ok:", "car" %in% ok, "\n")
cat("DONE\n")
