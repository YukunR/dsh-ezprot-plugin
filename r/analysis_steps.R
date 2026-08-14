# ===================================================================
# ==== Proteomics Data Analysis Pipeline with Checkpoint Support ====
# ===================================================================
# This file contains all analysis steps that can be called from your main script

# Load checkpoint system
source("utils/checkpoint.R")

# =====================================
# ========= Get Configuration =========
# =====================================

# Check if configuration variables exist in the global environment
# If not, set default values
get_config <- function() {
  config <- list()

  # Get configuration from global environment or set defaults
  config$base_dir <- if (exists("base_dir", envir = .GlobalEnv)) get("base_dir", envir = .GlobalEnv) else "./res/"
  config$protein_expr_file <- if (exists("protein_expr_file", envir = .GlobalEnv)) get("protein_expr_file", envir = .GlobalEnv) else "./data/origin_data.txt"
  config$sample_info_file <- if (exists("sample_info_file", envir = .GlobalEnv)) get("sample_info_file", envir = .GlobalEnv) else "./data/sample_info.txt"
  config$na_threshold <- if (exists("na_threshold", envir = .GlobalEnv)) get("na_threshold", envir = .GlobalEnv) else c(0.6, 0.9)
  config$normalization_method <- if (exists("normalization_method", envir = .GlobalEnv)) get("normalization_method", envir = .GlobalEnv) else "global"
  config$use_common_proteins_for_norm <- if (exists("use_common_proteins_for_norm", envir = .GlobalEnv)) get("use_common_proteins_for_norm", envir = .GlobalEnv) else FALSE
  config$imputation_method <- if (exists("imputation_method", envir = .GlobalEnv)) get("imputation_method", envir = .GlobalEnv) else "knn"
  config$comparisons <- if (exists("comparisons", envir = .GlobalEnv)) get("comparisons", envir = .GlobalEnv) else list()
  config$go_background_file <- if (exists("go_background_file", envir = .GlobalEnv)) get("go_background_file", envir = .GlobalEnv) else "./data/all_uniprot_go_background.csv"
  config$kegg_background_file <- if (exists("kegg_background_file", envir = .GlobalEnv)) get("kegg_background_file", envir = .GlobalEnv) else "./data/pathfromKegg_mmu.txt"
  config$custom_colors <- if (exists("custom_colors", envir = .GlobalEnv)) get("custom_colors", envir = .GlobalEnv) else NULL
  # FC threshold settings
  config$fc_threshold_mode <- if (exists("fc_threshold_mode", envir = .GlobalEnv)) get("fc_threshold_mode", envir = .GlobalEnv) else "auto"
  config$global_fc_threshold <- if (exists("global_fc_threshold", envir = .GlobalEnv)) get("global_fc_threshold", envir = .GlobalEnv) else 1.5
  # P-value threshold settings
  config$p_threshold_mode <- if (exists("p_threshold_mode", envir = .GlobalEnv)) get("p_threshold_mode", envir = .GlobalEnv) else "global"
  config$global_p_threshold <- if (exists("global_p_threshold", envir = .GlobalEnv)) get("global_p_threshold", envir = .GlobalEnv) else 0.05
  
  # Normalize comparisons
  names(config$comparisons) <- sapply(config$comparisons, `[[`, "name")
  return(config)
}

# ========================================================
# ========= Step 1: Normalization and Imputation =========
# ========================================================

step_normalization <- function(workspace, config = NULL) {
  if (is.null(config)) config <- get_config()

  log_message(workspace, "Starting data normalization and imputation")

  source("core/normalization.R", local = TRUE)

  # Read data (check.names = FALSE preserves original sample names with spaces,
  # e.g. "LFQ intensity NC_1"; default TRUE would mangle them to
  # "LFQ.intensity.NC_1" and break the sample_info <-> matrix join)
  protein_data <- read.delim(config$protein_expr_file, check.names = FALSE)
  sample_info <- read.delim(config$sample_info_file, check.names = FALSE)

  # Make directories
  norm_output_dir <- paste0(workspace$base_dir, "/norm_results/")
  if (!dir.exists(norm_output_dir)) {
    dir.create(norm_output_dir, recursive = TRUE)
  }

  # One-step processing
  separated_data <- separate_protein_data(protein_data, output_dir = norm_output_dir)
  calculate_na_percentage(separated_data$expression_data, output_dir = norm_output_dir)
  normalized_data <- normalize_by_median(
    separated_data$expression_data,
    sample_info,
    normalization_method = config$normalization_method,
    use_common_proteins = config$use_common_proteins_for_norm
  )
  log2_data <- log2_transform(normalized_data)
  imputed_data <- filter_and_impute(
    log2_data,
    sample_info,
    output_dir = norm_output_dir,
    filter_threshold = config$na_threshold,
    impute_method = config$imputation_method
  )
  protein_abundance_data <- 2^imputed_data %>%
    as.data.frame() %>%
    tibble::rownames_to_column("Accession")
  protein_annotation <- separated_data$annotation_data

  # If user did not specify a color, use default colors
  if (is.null(config$custom_colors)) {
    custom_colors <- generate_sample_colors(sample_info)$group_colors
  } else {
    custom_colors <- config$custom_colors
  }

  # Create comprehensive visualization
  workflow_result <- visualize_normalization_workflow(
    raw_data = separated_data$expression_data,
    normalized_data = normalized_data,
    imputed_data = imputed_data,
    sample_info = sample_info,
    custom_colors = custom_colors,
    output_dir = norm_output_dir
  )

  # Save color scheme
  color_scheme <- workflow_result$color_scheme
  write.csv(color_scheme$color_mapping, paste0(norm_output_dir, "/color_scheme.csv"), row.names = FALSE)

  save_processed_data(imputed_data, norm_output_dir)

  # Save intermediate results for subsequent steps
  saveRDS(list(
    imputed_data = imputed_data,
    protein_abundance_data = protein_abundance_data,
    protein_annotation = protein_annotation,
    color_scheme = color_scheme,
    sample_info = sample_info,
    config = config # Save config for next steps
  ), file.path(workspace$base_dir, "normalization_results.rds"))

  log_message(workspace, "Data normalization and imputation completed")
  return("Normalization completed")
}

# ===============================
# ========= Step 2: PCA =========
# ===============================

step_pca <- function(workspace) {
  log_message(workspace, "Starting PCA analysis")

  source("core/pca.R", local = TRUE)

  # Load results from previous step
  norm_results <- readRDS(file.path(workspace$base_dir, "normalization_results.rds"))

  # Make directories
  pca_output_dir <- paste0(workspace$base_dir, "/pca_results/")
  if (!dir.exists(pca_output_dir)) {
    dir.create(pca_output_dir, recursive = TRUE)
  }

  pca_input_data <- norm_results$imputed_data %>%
    as.data.frame() %>%
    tibble::rownames_to_column("Accession")

  pca_comprehensive <- run_comprehensive_pca(
    expression_data = pca_input_data,
    sample_info = norm_results$sample_info,
    group_colors = norm_results$color_scheme,
    output_dir = pca_output_dir,
    plot_width = 10,
    plot_height = 12
  )

  log_message(workspace, "PCA analysis completed")
  return("PCA completed")
}

# ===========================================
# ========= Step 2.5: Batch Removal =========
# ===========================================

step_batch_removal <- function(workspace) {
  log_message(workspace, "Starting batch removal assessment")

  source("core/batch_removal.R", local = TRUE)

  # Load results from previous steps
  norm_results <- readRDS(file.path(workspace$base_dir, "normalization_results.rds"))

  # ── Non-interactive mode (driven by the DSH ezprot plugin) ───────────────
  # Batch assignments must be supplied as a "Batch" column in
  # data/sample_info.txt. No console prompts are used.
  if (!"Batch" %in% colnames(norm_results$sample_info)) {
    log_message(workspace, "Batch removal skipped: no 'Batch' column in sample_info.txt")

    # Save decision for record
    saveRDS(list(
      batch_removal_performed = FALSE,
      imputed_data = norm_results$imputed_data,
      protein_abundance_data = norm_results$protein_abundance_data,
      protein_annotation = norm_results$protein_annotation,
      color_scheme = norm_results$color_scheme,
      sample_info = norm_results$sample_info,
      config = norm_results$config
    ), file.path(workspace$base_dir, "batch_removal_results.rds"))

    return("Batch removal skipped (no Batch column)")
  }

  # Batch information from the metadata file
  batch_info <- data.frame(
    Sample = norm_results$sample_info$Sample,
    Batch  = as.character(norm_results$sample_info$Batch),
    stringsAsFactors = FALSE
  )
  ref_batch <- NULL

  # Make output directory
  batch_output_dir <- paste0(workspace$base_dir, "/batch_removal_results/")
  if (!dir.exists(batch_output_dir)) {
    dir.create(batch_output_dir, recursive = TRUE)
  }

  # Save batch information
  write.csv(batch_info, file.path(batch_output_dir, "batch_assignments.csv"), row.names = FALSE)

  # Perform batch removal
  log_message(workspace, "Performing batch removal using ComBat")

  corrected_abundance <- remove_batch_effects(
    expression_data = norm_results$protein_abundance_data,
    batch_info = batch_info,
    sample_info = norm_results$sample_info,
    ref_batch = ref_batch,
    group_col = "Group",
    id_col = "Accession",
    log_transform = TRUE
  )

  # Also correct the log2-transformed data for downstream analysis
  imputed_data_df <- norm_results$imputed_data %>%
    as.data.frame() %>%
    tibble::rownames_to_column("Accession")

  corrected_log2 <- remove_batch_effects(
    expression_data = imputed_data_df,
    batch_info = batch_info,
    sample_info = norm_results$sample_info,
    ref_batch = ref_batch,
    group_col = "Group",
    id_col = "Accession",
    log_transform = FALSE # Already log2-transformed
  )

  # Convert back to matrix format for imputed_data
  corrected_imputed_matrix <- corrected_log2 %>%
    tibble::column_to_rownames("Accession") %>%
    as.matrix()

  # Visualize batch correction effects
  visualize_batch_correction(
    original_data = norm_results$protein_abundance_data,
    corrected_data = corrected_abundance,
    batch_info = batch_info,
    sample_info = norm_results$sample_info,
    output_dir = batch_output_dir
  )

  # Re-run PCA on corrected data for comparison
  cat("\nRe-running PCA on batch-corrected data...\n")
  pca_corrected_dir <- paste0(batch_output_dir, "/pca_after_correction/")
  if (!dir.exists(pca_corrected_dir)) {
    dir.create(pca_corrected_dir, recursive = TRUE)
  }

  source("core/pca.R", local = TRUE)

  pca_corrected <- run_comprehensive_pca(
    expression_data = corrected_log2,
    sample_info = norm_results$sample_info,
    group_colors = norm_results$color_scheme,
    output_dir = pca_corrected_dir,
    plot_width = 10,
    plot_height = 12
  )

  # Save corrected data for subsequent steps
  saveRDS(list(
    batch_removal_performed = TRUE,
    batch_info = batch_info,
    ref_batch = ref_batch,
    imputed_data = corrected_imputed_matrix,
    protein_abundance_data = corrected_abundance,
    protein_annotation = norm_results$protein_annotation,
    color_scheme = norm_results$color_scheme,
    sample_info = norm_results$sample_info,
    config = norm_results$config,
    original_data = list(
      imputed_data = norm_results$imputed_data,
      protein_abundance_data = norm_results$protein_abundance_data
    )
  ), file.path(workspace$base_dir, "batch_removal_results.rds"))

  log_message(workspace, "Batch removal completed successfully")
  cat("\nBatch removal completed. Results saved to:", batch_output_dir, "\n")
  cat("Please review the comparison plots to verify batch effect removal.\n")

  return("Batch removal completed")
}

# =====================================================
# ========= Step 3: Prepare Comparison Groups =========
# =====================================================

step_prepare_comparisons <- function(workspace, config = NULL) {
  if (is.null(config)) config <- get_config()

  log_message(workspace, "Preparing comparison groups for differential expression analysis")

  # Generate comparison groups
  source("core/comparison_groups.R", local = TRUE)

  # Check if batch removal was performed
  batch_removal_file <- file.path(workspace$base_dir, "batch_removal_results.rds")
  if (file.exists(batch_removal_file)) {
    data_source <- readRDS(batch_removal_file)
    if (data_source$batch_removal_performed) {
      log_message(workspace, "Using batch-corrected data for comparison groups")
    }
  } else {
    # Fall back to normalization results
    data_source <- readRDS(file.path(workspace$base_dir, "normalization_results.rds"))
  }

  comparison_groups <- create_comparison_groups(
    expression_data = data_source$protein_abundance_data,
    sample_info = data_source$sample_info,
    comparisons = config$comparisons
  )
  print_comparison_summary(comparison_groups)

  # Save comparison group information
  saveRDS(comparison_groups, file.path(workspace$base_dir, "comparison_groups.rds"))

  log_message(workspace, "Comparison groups preparation completed")
  return("Comparison groups prepared")
}

# ===========================================================================
# ========= Step 4: Differential Expression Analysis (Single Group) =========
# ===========================================================================

step_differential_analysis_single <- function(workspace, group_name, config = NULL) {
  if (is.null(config)) config <- get_config()

  log_message(workspace, paste("Starting processing comparison group:", group_name))

  # Load necessary data
  comparison_groups <- readRDS(file.path(workspace$base_dir, "comparison_groups.rds"))

  # Check if batch removal was performed
  batch_removal_file <- file.path(workspace$base_dir, "batch_removal_results.rds")
  if (file.exists(batch_removal_file)) {
    data_source <- readRDS(batch_removal_file)
  } else {
    data_source <- readRDS(file.path(workspace$base_dir, "normalization_results.rds"))
  }

  protein_annotation <- data_source$protein_annotation

  if (!group_name %in% names(comparison_groups)) {
    stop(paste("Comparison group", group_name, "does not exist"))
  }

  # Make directories
  dea_output_dir <- paste0(workspace$base_dir, "dea_results/")
  if (!dir.exists(dea_output_dir)) {
    dir.create(dea_output_dir, recursive = TRUE)
  }

  group_output_dir <- paste0(dea_output_dir, "/", group_name, "/")
  if (!dir.exists(group_output_dir)) {
    dir.create(group_output_dir, recursive = TRUE)
  }

  cat("Processing comparison group: ", group_name, "\n")
  cat("Results of DEA will be saved to folder: ", group_output_dir, "\n")

  # ==== T-test ====
  source("core/t_test.R", local = TRUE)
  ttest_results <- perform_ttest_analysis(
    expression_data = comparison_groups[[group_name]]$expression_data,
    sample_info = comparison_groups[[group_name]]$sample_info,
    control_group = comparison_groups[[group_name]]$control_name,
    treatment_group = comparison_groups[[group_name]]$treatment_name,
    normality_test = FALSE,
    equal_variance_test = TRUE,
    multiple_test_correction = "fdr",
    show_progress = TRUE
  )
  # Save t-test results
  write.csv(
    ttest_results,
    file = paste0(group_output_dir, "/t_test_result.csv"),
    row.names = FALSE
  )

  # ==== Coverage plot ====
  source("core/fc_coverage.R", local = TRUE)
  fc_coverage <- analyze_coverage(ttest_results, fc_column = "log2_fold_change")
  export_coverage_results(fc_coverage, output_dir = group_output_dir)

  # ==== Find comparison config for this group ====
  comparison_config <- NULL
  for (comp in config$comparisons) {
    if (comp$name == group_name) {
      comparison_config <- comp
      break
    }
  }

  # ==== Determine thresholds using threshold_utils ====
  source("core/volcano_threshold_determination.R", local = TRUE)
  thresholds <- determine_thresholds(
    ttest_results = ttest_results,
    group_name = group_name,
    config = config,
    comparison_config = comparison_config,
    fc_coverage_result = fc_coverage,
    fc_column = "log2_fold_change",
    output_dir = group_output_dir
  )

  fc_threshold <- thresholds$fc_threshold
  p_threshold <- thresholds$p_threshold

  # Log final thresholds
  log_message(
    workspace,
    paste(
      "FC threshold for", group_name, ":", fc_threshold,
      "(source:", thresholds$fc_source, ")"
    )
  )
  log_message(
    workspace,
    paste(
      "P-value threshold for", group_name, ":", p_threshold,
      "(source:", thresholds$p_source, ")"
    )
  )

  # ==== Volcano plot ====
  source("core/volcano_plot.R", local = TRUE)
  volcano_results <- create_volcano_plot(ttest_results,
    fc_column = "log2_fold_change",
    p_column = "p_value",
    fc_threshold = fc_threshold,
    p_threshold = p_threshold,
    gene_annotations = protein_annotation,
    annotation_counts = c(up = 10, down = 10),
    sort_method = "fc"
  )

  # Select useful info to save
  regulated_data <- volcano_results$data %>%
    merge(protein_annotation, by = "Accession") %>%
    select(
      Accession, GeneName, Description, control_mean,
      treatment_mean, log2_fold_change, p_value, regulation_group
    )

  write.csv(
    regulated_data,
    file = paste0(group_output_dir, "regulated_data.csv"),
    row.names = FALSE
  )

  # Save volcano plot
  ggsave(
    filename = paste0(group_output_dir, "volcano_plot.pdf"),
    plot = volcano_results$plot,
    width = 7,
    height = 7
  )
  # Plugin addition: PNG beside the PDF so the DSH chat can show it.
  ggsave(
    filename = paste0(group_output_dir, "volcano_plot.png"),
    plot = volcano_results$plot,
    width = 7,
    height = 7,
    dpi = 150
  )

  log_message(workspace, paste("Comparison group", group_name, "DEA completed"))
  return(paste("Comparison group", group_name, "DEA completed"))
}

# ===========================================================================
# ==== Step 4b: Enrichment Analysis (Single Comparison, plugin-driven) =====
# ===========================================================================
step_enrichment_single <- function(workspace, group_name, config = NULL) {
  if (is.null(config)) config <- get_config()
  log_message(workspace, paste("Starting enrichment analysis for:", group_name))

  group_output_dir <- paste0(workspace$base_dir, "/dea_results/", group_name, "/")
  regulated_file <- paste0(group_output_dir, "/regulated_data.csv")
  if (!file.exists(regulated_file)) {
    stop(paste("regulated_data.csv not found for", group_name,
               "- run the dea step first"))
  }
  regulated_data <- read.csv(regulated_file, check.names = FALSE)

  enrich_output_dir <- paste0(group_output_dir, "/enrichment_results/")
  if (!dir.exists(enrich_output_dir)) {
    dir.create(enrich_output_dir, recursive = TRUE)
  }

  source("core/enrichment_analysis.R", local = TRUE)
  go_background <- read.csv(config$go_background_file, check.names = FALSE)
  kegg_background <- read.delim(config$kegg_background_file, check.names = FALSE)

  up_regulated_proteins <- regulated_data %>%
    filter(regulation_group == "up") %>%
    select(Accession)
  down_regulated_proteins <- regulated_data %>%
    filter(regulation_group == "down") %>%
    select(Accession)
  all_regulated_proteins <- rbind(up_regulated_proteins, down_regulated_proteins)

  enrich_list <- list(up_regulated_proteins, down_regulated_proteins, all_regulated_proteins)
  regulation_types <- c("up", "down", "all")

  for (i in 1:3) {
    tryCatch(
      {
        regulation_type <- regulation_types[i]
        regulated_proteins_tmp <- enrich_list[[i]]
        enrich_results <- run_combined_analysis(
          gene_list = regulated_proteins_tmp$Accession,
          go_background = go_background,
          kegg_background = kegg_background,
          p_threshold = 1,
          output_dir = enrich_output_dir,
          file_prefix = paste0("analysis_", regulation_type),
          plot_format = "pdf"
        )
        if (nrow(enrich_results$go_results) > 0) {
          ggsave(paste0(enrich_output_dir, "GObarplot_", regulation_type, ".tiff"),
            enrich_results$plots$go_barplot,
            width = 12, height = 8, dpi = 300
          )
        }

        if (nrow(enrich_results$kegg_results) > 0) {
          ggsave(paste0(enrich_output_dir, "KEGGdotplot_", regulation_type, ".tiff"),
            enrich_results$plots$kegg_plots$dot,
            width = 10, height = 8, dpi = 300
          )
        }
      },
      error = function(e) {
        cat("Error occurred when enriching: ", group_name, regulation_type, "-regulated proteins, skipping.\n")
      }
    )
  }

  log_message(workspace, paste("Enrichment analysis completed for:", group_name))
  return(paste("Enrichment completed for", group_name))
}

# ===========================================================================
# ==== Step 4c: GSEA (Single Comparison, plugin-driven) =====================
# ===========================================================================
step_gsea_single <- function(workspace, group_name, config = NULL) {
  if (is.null(config)) config <- get_config()
  log_message(workspace, paste("Starting GSEA for:", group_name))

  group_output_dir <- paste0(workspace$base_dir, "/dea_results/", group_name, "/")
  regulated_file <- paste0(group_output_dir, "/regulated_data.csv")
  if (!file.exists(regulated_file)) {
    stop(paste("regulated_data.csv not found for", group_name,
               "- run the dea step first"))
  }
  regulated_data <- read.csv(regulated_file, check.names = FALSE)

  gsea_output_dir <- paste0(group_output_dir, "/gsea_results/")
  if (!dir.exists(gsea_output_dir)) {
    dir.create(gsea_output_dir, recursive = TRUE)
  }

  source("core/gsea.R", local = TRUE)
  kegg_background <- read.delim(config$kegg_background_file, check.names = FALSE)
  term2gene <- kegg_background %>% select(PATH, UNIPROT)
  term2name <- kegg_background %>% select(PATH, PATHNAME)
  results <- run_gsea_workflow(
    gene_data = regulated_data,
    gene_column = "Accession",
    fc_column = "log2_fold_change",
    p_column = "p_value",
    term2gene = term2gene,
    term2name = term2name,
    output_dir = gsea_output_dir,
    file_prefix = "gsea"
  )

  log_message(workspace, paste("GSEA completed for:", group_name))
  return(paste("GSEA completed for", group_name))
}

#' Build threshold config for tracking
#'
#' @param config Configuration from get_config()
#' @param group_name Name of comparison group
#' @return List of threshold-related config to track
build_threshold_config_for_tracking <- function(config, group_name = NULL) {
  # Core threshold settings
  threshold_config <- list(
    fc_threshold_mode = config$fc_threshold_mode,
    global_fc_threshold = config$global_fc_threshold,
    p_threshold_mode = config$p_threshold_mode,
    global_p_threshold = config$global_p_threshold
  )

  # If group_name provided, also include comparison-specific thresholds
  if (!is.null(group_name) && length(config$comparisons) > 0) {
    for (comp in config$comparisons) {
      if (comp$name == group_name) {
        threshold_config$comparison_fc_threshold <- comp$fc_threshold
        threshold_config$comparison_p_threshold <- comp$p_threshold
        break
      }
    }
  }

  return(threshold_config)
}

# ==========================================
# ========= Main Analysis Pipeline =========
# ==========================================

run_proteomics_analysis <- function(project_name = "proteomics_project", force_rerun_list = NULL) {
  # Get configuration from global environment
  config <- get_config()

  # Create workspace
  workspace <- create_workspace(project_name, config$base_dir)

  log_message(workspace, "Starting proteomics data analysis pipeline")
  log_message(workspace, paste("Configuration loaded - Base dir:", config$base_dir))
  log_message(workspace, paste("Protein expression file:", config$protein_expr_file))
  log_message(workspace, paste("Sample info file:", config$sample_info_file))
  log_message(workspace, paste("Number of comparisons:", length(config$comparisons)))

  # Load and check existing checkpoint
  checkpoint <- load_checkpoint(workspace)

  if (length(checkpoint$completed_steps) > 0) {
    log_message(workspace, paste("Found existing checkpoint with completed steps:", paste(checkpoint$completed_steps, collapse = ", ")))
    cat("Resuming analysis from checkpoint...\n")
    cat("Completed steps:", paste(checkpoint$completed_steps, collapse = ", "), "\n")
  } else {
    cat("Starting fresh analysis...\n")
  }

  # Check for forced rerun steps
  if (!is.null(force_rerun_list)) {
    force_rerun_steps(force_rerun_list, project_name, config$base_dir)
    log_message(workspace, paste("Forced rerun of steps:", paste(force_rerun_list, collapse = ", ")))
    cat("Forced rerun of steps:", paste(force_rerun_list, collapse = ", "), "\n")
  }

  # Step 1: Data normalization and imputation
  cat("\n=== Step 1: Data Normalization and Imputation ===\n")
  execute_step(
    workspace = workspace,
    step_name = "normalization",
    step_function = step_normalization,
    output_files = c("normalization_results.rds"),
    config_to_track = list(
      normalization_method = config$normalization_method,
      imputation_method = config$imputation_method,
      na_threshold = config$na_threshold
    ),
    cleanup_patterns = c("norm_results/.*"),
    config = config
  )

  # Step 2: PCA analysis
  cat("\n=== Step 2: PCA Analysis ===\n")
  execute_step(
    workspace = workspace,
    step_name = "pca",
    step_function = step_pca,
    output_files = c("pca_results/pca_biplot_PC1_PC2.pdf"),
    dependencies = "normalization",
    cleanup_patterns = c("pca_results/.*")
  )

  # Step 2.5: Batch Removal (Optional)
  cat("\n=== Step 2.5: Batch Removal (Optional) ===\n")
  execute_step(
    workspace = workspace,
    step_name = "batch_removal",
    step_function = step_batch_removal,
    output_files = c("batch_removal_results.rds"),
    dependencies = c("normalization", "pca"),
    cleanup_patterns = c("batch_removal_results/.*")
  )

  # Step 3: Prepare comparison groups
  # Track comparison configuration to detect changes
  cat("\n=== Step 3: Prepare Comparison Groups ===\n")
  execute_step(
    workspace = workspace,
    step_name = "prepare_comparisons",
    step_function = step_prepare_comparisons,
    output_files = "comparison_groups.rds",
    config_to_track = config$comparisons,
    dependencies = "normalization",
    config = config
  )

  # Step 4: Differential expression analysis for each comparison group
  cat("\n=== Step 4: Differential Expression Analysis ===\n")

  # Get current comparison names from config
  current_comparison_names <- sapply(config$comparisons, function(x) x$name)

  for (i in seq_along(config$comparisons)) {
    comparison <- config$comparisons[[i]]
    group_name <- comparison$name
    step_name <- paste0("differential_analysis_", group_name)

    cat(sprintf("Processing comparison %d/%d: %s\n", i, length(config$comparisons), group_name))

    # Track the specific comparison config for this group
    execute_step(
      workspace = workspace,
      step_name = step_name,
      step_function = step_differential_analysis_single,
      output_files = c(
        paste0("dea_results/", group_name, "/t_test_result.csv"),
        paste0("dea_results/", group_name, "/regulated_data.csv"),
        paste0("dea_results/", group_name, "/volcano_plot.pdf"),
        paste0("dea_results/", group_name, "/threshold_info.csv")
      ),
      dependencies = c("normalization"),
      config_to_track = comparison,
      cleanup_patterns = paste0("dea_results/", group_name, "/.*"),
      group_name = group_name,
      config = config
    )
  }

  log_message(workspace, "Analysis pipeline completed successfully!")
  cat("\n=== Analysis Pipeline Completed Successfully! ===\n")
  cat("Results directory:", workspace$base_dir, "\n")

  # Return results summary
  return(list(
    workspace = workspace,
    status = "completed",
    results_dir = workspace$base_dir,
    config = config
  ))
}

# =====================================
# ========= Utility Functions =========
# =====================================

# Wrapper function for rerunning specific steps
rerun_step <- function(step_names, project_name = "proteomics_project") {
  run_proteomics_analysis(project_name, force_rerun_list = step_names)
}

# Print configuration summary
print_config <- function() {
  config <- get_config()
  cat("=== Current Configuration ===\n\n")

  cat("--- Data Files ---\n")
  cat("Base directory:", config$base_dir, "\n")
  cat("Protein expression file:", config$protein_expr_file, "\n")
  cat("Sample info file:", config$sample_info_file, "\n")

  cat("\n--- Normalization Settings ---\n")
  if (length(config$na_threshold) == 1) {
    cat("NA threshold:", config$na_threshold, "\n")
  } else if (length(config$na_threshold) == 2) {
    cat("NA threshold (two-threshold mode):", paste(config$na_threshold, collapse = ", "), "\n")
    cat("  For auto mode: < ", config$na_threshold[1], " -> KNN, ",
        config$na_threshold[1], " to ", config$na_threshold[2], " -> Perseus, >= ",
        config$na_threshold[2], " -> discard\n", sep = "")
  } else {
    cat("NA threshold:", paste(config$na_threshold, collapse = ", "), "\n")
  }
  cat("Normalization method:", config$normalization_method, "\n")
  cat("Imputation method:", config$imputation_method, "\n")

  cat("\n--- Threshold Settings ---\n")
  cat("FC threshold mode:", config$fc_threshold_mode)
  if (config$fc_threshold_mode == "auto") {
    cat(" (will auto-calculate using coverage analysis)\n")
    if (config$global_fc_threshold != 1.5) {
      cat("  [!] global_fc_threshold (", config$global_fc_threshold, ") will be IGNORED\n")
    }
  } else if (config$fc_threshold_mode == "global") {
    cat(" -> global_fc_threshold:", config$global_fc_threshold, "\n")
  } else {
    cat(" (per-comparison or interactive)\n")
  }

  cat("P-value threshold mode:", config$p_threshold_mode)
  if (config$p_threshold_mode == "global") {
    cat(" -> global_p_threshold:", config$global_p_threshold, "\n")
  } else {
    cat(" (per-comparison or interactive)\n")
  }

  cat("\n--- Comparisons ---\n")
  cat("Number of comparisons:", length(config$comparisons), "\n")
  if (length(config$comparisons) > 0) {
    for (i in seq_along(config$comparisons)) {
      comp <- config$comparisons[[i]]
      ctrl_str <- if (length(comp$control) > 1) paste(comp$control, collapse = "+") else comp$control
      treat_str <- if (length(comp$treatment) > 1) paste(comp$treatment, collapse = "+") else comp$treatment

      # Check for thresholds in comparison
      thresh_parts <- c()
      if (!is.null(comp$fc_threshold)) {
        if (config$fc_threshold_mode == "auto") {
          thresh_parts <- c(thresh_parts, paste0("FC=", comp$fc_threshold, " [IGNORED]"))
        } else {
          thresh_parts <- c(thresh_parts, paste0("FC=", comp$fc_threshold))
        }
      }
      if (!is.null(comp$p_threshold)) {
        thresh_parts <- c(thresh_parts, paste0("P=", comp$p_threshold))
      }
      thresh_str <- if (length(thresh_parts) > 0) paste0(" [", paste(thresh_parts, collapse = ", "), "]") else ""

      cat(sprintf("  %d. %s vs %s (%s)%s\n", i, treat_str, ctrl_str, comp$name, thresh_str))
    }
  }

  cat("\n--- Enrichment Analysis ---\n")
  cat("GO background file:", config$go_background_file, "\n")
  cat("KEGG background file:", config$kegg_background_file, "\n")
  cat("Custom colors:", ifelse(is.null(config$custom_colors), "Not specified", "Specified"), "\n")
  cat("\n=============================\n")
}

# Enhanced status check with troubleshooting
check_status <- function(project_name = "proteomics_project") {
  config <- get_config()
  check_project_status(project_name, config$base_dir)
}

# Reset interrupted step
reset_interrupted <- function(project_name = "proteomics_project") {
  config <- get_config()
  reset_interrupted_step(project_name, config$base_dir)
}

# Verify all files
verify_files <- function(project_name = "proteomics_project") {
  config <- get_config()
  verify_checkpoint_files(project_name, config$base_dir)
}

# Clean project with confirmation
clean_project_safe <- function(project_name = "proteomics_project") {
  config <- get_config()

  cat("This will delete all checkpoint data and restart the analysis from the beginning.\n")
  cat("Are you sure? (y/N): ")
  response <- readline()

  if (tolower(response) %in% c("y", "yes")) {
    clean_project(project_name, config$base_dir)
    cat("Project cleaned. Next run will start from the beginning.\n")
  } else {
    cat("Operation cancelled.\n")
  }
}

# Troubleshooting helper
troubleshoot <- function(project_name = "proteomics_project") {
  cat("=== Troubleshooting Guide ===\n")
  cat("1. Check current status:\n")
  check_status(project_name)
  cat("\n")

  config <- get_config()
  checkpoint_file <- file.path(config$base_dir, "checkpoint.json")

  if (file.exists(checkpoint_file)) {
    checkpoint <- fromJSON(checkpoint_file)

    if (!is.null(checkpoint$current_step)) {
      cat("2. Found interrupted step. Recommendations:\n")
      cat("   - Run reset_interrupted() to clear the interrupted step\n")
      cat("   - Then run run_proteomics_analysis() to continue\n\n")
    }

    cat("3. Verify file integrity:\n")
    verify_files(project_name)
    cat("\n")

    cat("4. Available commands:\n")
    cat("   - reset_interrupted(): Reset interrupted step\n")
    cat("   - verify_files(): Check file integrity\n")
    cat("   - rerun_step(c('step1', 'step2')): Force rerun specific steps\n")
    cat("   - clean_project_safe(): Clean and restart (with confirmation)\n")
  } else {
    cat("2. No checkpoint file found. This is a fresh start.\n")
  }

  cat("==============================\n")
}

# Add new comparisons without rerunning everything
add_comparisons <- function(new_comparisons, project_name = "proteomics_project") {
  config <- get_config()
  workspace <- create_workspace(project_name, config$base_dir)

  cat("Adding new comparisons to the analysis...\n")
  cat("New comparisons will trigger re-run of prepare_comparisons step.\n")

  # The config$comparisons should already include the new comparisons
  # Just force rerun prepare_comparisons
  force_rerun_steps("prepare_comparisons", project_name, config$base_dir)

  cat("Run run_proteomics_analysis() to execute the new comparisons.\n")
}