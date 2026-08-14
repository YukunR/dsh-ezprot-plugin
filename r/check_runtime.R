#!/usr/bin/env Rscript
# check_runtime.R <manifest.json>
# Runtime capability probe: verifies that every manifest package loads AND
# that the heavy pipeline code paths actually work (the ggalt-class gaps that
# static manifest checks cannot see, e.g. PCAtools' biplot(encircle=TRUE)
# needing the Suggests-only ggalt). Exit 1 when any probe fails.
suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("jsonlite not installed")
  }
  library(jsonlite)
})
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: check_runtime.R <manifest.json>")
m <- fromJSON(args[1])

failures <- character()
probe <- function(name, expr) {
  res <- tryCatch({
    value <- force(expr)
    # requireNamespace returns TRUE/FALSE (never throws): FALSE must fail.
    if (isFALSE(value)) FALSE else TRUE
  }, error = function(e) conditionMessage(e))
  if (isTRUE(res)) {
    cat("CHECK_OK:", name, "\n")
  } else {
    cat("CHECK_FAIL:", name, "-", res, "\n")
    failures <<- c(failures, name)
  }
}

for (p in c(m$cran, m$bioc)) {
  probe(paste0("load:", p), requireNamespace(p, quietly = TRUE))
}

# PCAtools pca + biplot with encircle (the ggalt code path)
probe("pcatools:biplot-encircle", {
  suppressPackageStartupMessages(library(PCAtools))
  mat <- matrix(rnorm(20 * 6), nrow = 20, ncol = 6,
    dimnames = list(paste0("P", 1:20), paste0("S", 1:6)))
  meta <- data.frame(row.names = paste0("S", 1:6), group = rep(c("A", "B"), 3))
  p <- pca(mat, metadata = meta)
  plt <- biplot(p, encircle = TRUE, encircleFill = TRUE)
  invisible(plt)
})

# ComBat batch correction path
probe("sva:combat", {
  suppressPackageStartupMessages(library(sva))
  mat <- matrix(rnorm(20 * 6), nrow = 20, ncol = 6)
  batch <- rep(c(1, 2), 3)
  mod <- model.matrix(~ 1, data = data.frame(x = rep(1, 6)))
  corrected <- ComBat(dat = mat, batch = batch, mod = mod)
  invisible(corrected)
})

# clusterProfiler enricher path (local backgrounds)
probe("clusterprofiler:enricher", {
  suppressPackageStartupMessages(library(clusterProfiler))
  term2gene <- data.frame(term = c("T1", "T1", "T2"), gene = c("G1", "G2", "G3"))
  term2name <- data.frame(term = c("T1", "T2"), name = c("Term 1", "Term 2"))
  res <- enricher(c("G1", "G2"), TERM2GENE = term2gene, TERM2NAME = term2name,
    pvalueCutoff = 1, qvalueCutoff = 1, minGSSize = 1, maxGSSize = 10)
  invisible(res)
})

if (length(failures) > 0) {
  cat("CHECK_RESULT: FAIL (", paste(failures, collapse = ", "), ")\n", sep = "")
  quit(status = 1)
}
cat("CHECK_RESULT: ALL OK\n")
