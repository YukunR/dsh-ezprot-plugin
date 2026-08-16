#!/usr/bin/env Rscript
# run.R - ezprot pipeline step driver (non-interactive, invoked by the DSH plugin)
# Usage: Rscript run.R <step> [--rerun step1,step2]
#   <step> = all | normalization | pca | batch-removal | dea | enrich | gsea

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("Usage: Rscript run.R <step> [--rerun step1,step2]")
step <- args[1]

force_rerun_list <- NULL
if ("--rerun" %in% args) {
  idx <- which(args == "--rerun")
  if (idx < length(args)) force_rerun_list <- trimws(strsplit(args[idx + 1], ",")[[1]])
}

# Run from the script's directory
this_file <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
setwd(dirname(this_file))

source("main.R")          # configuration + pipeline functions
config <- get_config()
workspace <- create_workspace("proteomics_project", config$base_dir)

run_one <- function(step_name, step_function, output_files, dependencies = NULL,
                    config_to_track = NULL, cfg = NULL, cleanup_patterns = NULL,
                    force = NULL) {
  force_rerun_flag <- if (!is.null(force)) force else (!is.null(force_rerun_list) && step_name %in% force_rerun_list)
  if (!is.null(cfg)) {
    execute_step(
      workspace       = workspace,
      step_name       = step_name,
      step_function   = step_function,
      output_files    = output_files,
      dependencies    = dependencies,
      force_rerun     = force_rerun_flag,
      config_to_track = config_to_track,
      cleanup_patterns = cleanup_patterns,
      config          = cfg
    )
  } else {
    execute_step(
      workspace       = workspace,
      step_name       = step_name,
      step_function   = step_function,
      output_files    = output_files,
      dependencies    = dependencies,
      force_rerun     = force_rerun_flag,
      config_to_track = config_to_track,
      cleanup_patterns = cleanup_patterns
    )
  }
}

cat("=== ezprot run.R:", step, "===\n")

# Per-comparison enrichment/GSEA steps run through execute_step so they get
# the same checkpointing as every other stage (completion markers, output
# file hashes, config tracking, dependency validation, force-rerun support).
run_enrichment <- function() {
  for (cname in names(config$comparisons)) {
    local({
      cn <- cname
      run_one(paste0("enrichment_", cn),
        function(ws, ...) step_enrichment_single(ws, cn, config),
        c(
          paste0("dea_results/", cn, "/enrichment_results/analysis_all_go_results.csv"),
          paste0("dea_results/", cn, "/enrichment_results/analysis_all_kegg_results.csv")
        ),
        dependencies = c("normalization", paste0("differential_analysis_", cn)),
        config_to_track = config$comparisons[[cn]],
        cfg = config,
        cleanup_patterns = paste0("dea_results/", cn, "/enrichment_results/.*"),
        force = !is.null(force_rerun_list) && any(c("enrich", paste0("enrichment_", cn)) %in% force_rerun_list))
    })
  }
}

run_gsea <- function() {
  for (cname in names(config$comparisons)) {
    local({
      cn <- cname
      run_one(paste0("gsea_", cn),
        function(ws, ...) step_gsea_single(ws, cn, config),
        paste0("dea_results/", cn, "/gsea_results/gsea_results.csv"),
        dependencies = c("normalization", paste0("differential_analysis_", cn)),
        config_to_track = config$comparisons[[cn]],
        cfg = config,
        cleanup_patterns = paste0("dea_results/", cn, "/gsea_results/.*"),
        force = !is.null(force_rerun_list) && any(c("gsea", paste0("gsea_", cn)) %in% force_rerun_list))
    })
  }
}

if (step == "all") {
  run_proteomics_analysis(force_rerun_list = force_rerun_list)
  run_enrichment()
  run_gsea()

} else if (step == "normalization") {
  run_one("normalization", step_normalization, c("normalization_results.rds"),
    config_to_track = list(
      normalization_method = config$normalization_method,
      imputation_method    = config$imputation_method,
      na_threshold         = config$na_threshold
    ),
    cfg = config,
    cleanup_patterns = c("norm_results/.*"))

} else if (step == "pca") {
  run_one("pca", step_pca, c("pca_results/pca_biplot_PC1_PC2.pdf"),
    dependencies = "normalization",
    cleanup_patterns = c("pca_results/.*"))

} else if (step == "batch-removal") {
  run_one("batch_removal", step_batch_removal, c("batch_removal_results.rds"),
    dependencies = c("normalization", "pca"),
    cleanup_patterns = c("batch_removal_results/.*"),
    force = !is.null(force_rerun_list) && "batch-removal" %in% force_rerun_list)

} else if (step == "dea") {
  run_one("prepare_comparisons", step_prepare_comparisons, "comparison_groups.rds",
    dependencies = "normalization",
    config_to_track = config$comparisons,
    cfg = config,
    force = !is.null(force_rerun_list) && any(c("dea", "prepare_comparisons") %in% force_rerun_list))
  for (cname in names(config$comparisons)) {
    local({
      cn <- cname
      run_one(paste0("differential_analysis_", cn),
        function(ws, ...) step_differential_analysis_single(ws, cn, config),
        c(
          paste0("dea_results/", cn, "/t_test_result.csv"),
          paste0("dea_results/", cn, "/regulated_data.csv"),
          paste0("dea_results/", cn, "/volcano_plot.pdf"),
          paste0("dea_results/", cn, "/threshold_info.csv")
        ),
        dependencies = "normalization",
        config_to_track = config$comparisons[[cn]],
        cfg = config,
        cleanup_patterns = paste0("dea_results/", cn, "/.*"),
        force = !is.null(force_rerun_list) && any(c("dea", paste0("differential_analysis_", cn)) %in% force_rerun_list))
    })
  }

} else if (step == "enrich") {
  run_enrichment()

} else if (step == "gsea") {
  run_gsea()

} else {
  stop("Unknown step: ", step)
}

cat("=== ezprot run.R done:", step, "===\n")
