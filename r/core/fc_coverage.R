# ==============================================================================
# PROTEOMICS COVERAGE ANALYSIS FUNCTIONS
# ==============================================================================
# Functions for analyzing protein fold change coverage and threshold inference
#
# Features:
# - Flexible fold change column selection (FC, log2FC, fold_change, etc.)
# - Automatic detection of log2 vs linear fold change values
# - Publication-ready visualizations
# - Comprehensive threshold inference
# - Export capabilities for results
#
# Usage Examples:
# 1. Basic analysis with default FC column:
#    results <- analyze_coverage(protein_data)
#
# 2. Custom fold change column:
#    results <- analyze_coverage(protein_data, fc_column = "log2FC")
#
# 3. Find potential fold change columns:
#    candidates <- identify_fc_columns(protein_data)
#
# ==============================================================================

library(dplyr)
library(ggplot2)

# ==============================================================================
# FOLD CHANGE COVERAGE CALCULATION
# ==============================================================================

#' Calculate Fold Change Coverage Distribution
#'
#' Bins proteins by their fold change values and calculates cumulative coverage.
#' This function categorizes proteins into percentage change bins and computes
#' the cumulative distribution for threshold inference.
#'
#' @param gene_data A data frame containing protein expression data from t-test analysis
#' @param fc_column Name of the column containing fold change values (default: "FC")
#' @param fc_thresholds A numeric vector of fold change thresholds (default: 1.1 to 2.0 by 0.1)
#'
#' @return A data frame with columns:
#'   - bin: Factor with fold change percentage bins
#'   - count: Number of proteins in each bin
#'   - cumulative: Cumulative coverage proportion
#'
#' @examples
#' # Using default FC column
#' coverage_data <- calculate_coverage(protein_data)
#'
#' # Using custom fold change column
#' coverage_data <- calculate_coverage(protein_data, fc_column = "fold_change")
#' coverage_data <- calculate_coverage(protein_data, fc_column = "log2FC")
#'
#' @export
calculate_coverage <- function(gene_data, fc_column = "FC", fc_thresholds = seq(1.1, 2.0, 0.1)) {
  # Input validation
  if (!is.data.frame(gene_data)) {
    stop("gene_data must be a data frame")
  }

  if (!fc_column %in% colnames(gene_data)) {
    stop(paste(
      "Column", fc_column, "not found in gene_data. Available columns:",
      paste(colnames(gene_data), collapse = ", ")
    ))
  }

  if (any(is.na(gene_data[[fc_column]]))) {
    warning(paste("NA values found in", fc_column, "column, these will be removed"))
    gene_data <- gene_data[!is.na(gene_data[[fc_column]]), ]
  }

  # Check if the fold change values are reasonable
  fc_values <- gene_data[[fc_column]]
  if (all(fc_values <= 0)) {
    stop("All fold change values are <= 0. Please check your data.")
  }

  # Define percentage bins based on fold change thresholds
  bin_labels <- c(
    paste0("<", (fc_thresholds - 1) * 100, "%"),
    paste0(">=", (max(fc_thresholds) - 1) * 100, "%")
  )

  # Detect if the input is already log2 transformed
  # If most values are between -10 and 10, likely already log2 transformed
  if (all(abs(fc_values) <= 15) && any(fc_values < 0)) {
    message("Input appears to be log2 transformed. Using values directly.")
    gene_data$log2_fc <- fc_values
  } else {
    # Calculate log2 fold change for binning
    gene_data$log2_fc <- log2(fc_values)
  }

  # Create bins using cut function for cleaner code
  log2_breaks <- c(-Inf, -rev(log2(fc_thresholds)), log2(fc_thresholds), Inf)

  # Assign bins based on absolute log2 fold change
  gene_data$bin <- cut(
    abs(gene_data$log2_fc),
    breaks = c(0, log2(fc_thresholds), Inf),
    labels = bin_labels,
    include.lowest = TRUE,
    right = FALSE
  )

  # Count proteins in each bin
  gene_bin <- gene_data %>%
    count(bin, name = "count") %>%
    mutate(bin = factor(bin, levels = bin_labels))

  # Ensure all bins are represented (add missing bins with count = 0)
  complete_bins <- data.frame(
    bin = factor(bin_labels, levels = bin_labels),
    count = 0
  )

  gene_bin <- complete_bins %>%
    left_join(gene_bin, by = "bin") %>%
    mutate(count = coalesce(count.y, count.x)) %>%
    select(bin, count)

  # Calculate cumulative coverage
  total_proteins <- sum(gene_bin$count)
  gene_bin$cumulative <- cumsum(gene_bin$count) / total_proteins

  # Add threshold values for inference
  gene_bin$threshold <- c(fc_thresholds, max(fc_thresholds))

  return(gene_bin)
}


# ==============================================================================
# THRESHOLD INFERENCE
# ==============================================================================

#' Infer Optimal Fold Change Threshold
#'
#' Determines the optimal fold change threshold based on desired coverage.
#' This function finds the minimum fold change that achieves the target coverage.
#'
#' @param gene_bin A data frame generated by calculate_coverage()
#' @param coverage_threshold The desired coverage threshold (default: 0.88)
#'
#' @return The inferred fold change threshold as a numeric value
#'
#' @examples
#' # Infer threshold for 88% coverage
#' threshold <- infer_threshold(coverage_data, 0.88)
#'
#' @export
infer_threshold <- function(gene_bin, coverage_threshold = 0.88) {
  # Input validation
  if (!is.data.frame(gene_bin)) {
    stop("gene_bin must be a data frame")
  }

  required_cols <- c("cumulative", "threshold")
  missing_cols <- setdiff(required_cols, colnames(gene_bin))
  if (length(missing_cols) > 0) {
    stop(paste("Missing required columns:", paste(missing_cols, collapse = ", ")))
  }

  if (coverage_threshold < 0 || coverage_threshold > 1) {
    stop("coverage_threshold must be between 0 and 1")
  }

  # Find the first threshold that meets the coverage requirement
  threshold_idx <- which(gene_bin$cumulative >= coverage_threshold)[1]

  if (is.na(threshold_idx)) {
    warning("Coverage threshold not achievable with current data")
    return(max(gene_bin$threshold, na.rm = TRUE))
  }

  return(gene_bin$threshold[threshold_idx])
}


# ==============================================================================
# COVERAGE VISUALIZATION
# ==============================================================================

#' Create Coverage Plot
#'
#' Generates a publication-ready coverage plot showing protein distribution
#' across fold change bins with cumulative coverage overlay.
#'
#' @param gene_bin A data frame generated by calculate_coverage()
#' @param coverage_threshold The coverage threshold line to display (default: 0.88)
#' @param title Plot title (default: "Protein Fold Change Coverage Analysis")
#' @param colors A list with 'bar' and 'line' colors for customization
#'
#' @return A ggplot2 object
#'
#' @examples
#' # Create basic coverage plot
#' p <- create_coverage_plot(coverage_data)
#'
#' # Customize colors and threshold
#' p <- create_coverage_plot(coverage_data,
#'   coverage_threshold = 0.9,
#'   colors = list(bar = "#2E8B57", line = "#FF6347")
#' )
#'
#' @export
create_coverage_plot <- function(gene_bin,
                                 coverage_threshold = 0.88,
                                 title = "Protein Fold Change Coverage Analysis",
                                 colors = list(bar = "#698e31", line = "#E7B800")) {
  # Input validation
  if (!is.data.frame(gene_bin)) {
    stop("gene_bin must be a data frame")
  }

  required_cols <- c("bin", "count", "cumulative")
  missing_cols <- setdiff(required_cols, colnames(gene_bin))
  if (length(missing_cols) > 0) {
    stop(paste("Missing required columns:", paste(missing_cols, collapse = ", ")))
  }

  # Calculate total count for scaling
  total_count <- sum(gene_bin$count)

  # Create the plot
  coverage_plot <- ggplot(gene_bin, aes(x = bin)) +

    # Bar plot for protein counts
    geom_col(aes(y = count),
      fill = colors$bar,
      alpha = 0.8,
      width = 0.7
    ) +

    # Line plot for cumulative coverage
    geom_line(aes(y = cumulative * total_count, group = 1),
      linewidth = 1.5,
      color = colors$line
    ) +

    # Points for cumulative coverage
    geom_point(aes(y = cumulative * total_count),
      color = colors$line,
      size = 2
    ) +

    # Horizontal line for coverage threshold
    geom_hline(
      yintercept = coverage_threshold * total_count,
      linetype = "dashed",
      linewidth = 1,
      color = "#E74C3C",
      alpha = 0.8
    ) +

    # Annotation for threshold line
    annotate("text",
      x = length(levels(gene_bin$bin)) * 0.8,
      y = coverage_threshold * total_count * 1.1,
      label = paste0(coverage_threshold * 100, "% Coverage"),
      color = "#E74C3C",
      size = 3.5,
      fontface = "italic"
    ) +

    # Scales and labels
    scale_y_continuous(
      name = "Protein Count",
      sec.axis = sec_axis(
        trans = ~ . * 100 / total_count,
        name = "Cumulative Coverage (%)",
        labels = function(x) paste0(x, "%")
      )
    ) +
    scale_x_discrete(name = "Fold Change Bins") +

    # Theme and styling
    labs(
      title = title,
      subtitle = paste("Total proteins analyzed:", total_count),
      caption = "Bars: protein count per bin | Line: cumulative coverage"
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
      plot.subtitle = element_text(size = 12, hjust = 0.5, color = "gray60"),
      plot.caption = element_text(size = 10, color = "gray50"),
      axis.title = element_text(size = 12, face = "bold"),
      axis.text = element_text(size = 10),
      axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
      axis.title.y.right = element_text(color = colors$line),
      axis.text.y.right = element_text(color = colors$line),
      panel.grid.minor = element_blank(),
      panel.grid.major.x = element_blank(),
      legend.position = "none"
    )

  return(coverage_plot)
}


# ==============================================================================
# COMPREHENSIVE COVERAGE ANALYSIS WRAPPER
# ==============================================================================

#' Complete Coverage Analysis Workflow
#'
#' Performs the complete coverage analysis workflow including calculation,
#' threshold inference, and visualization.
#'
#' @param gene_data A data frame containing protein expression data
#' @param fc_column Name of the column containing fold change values (default: "FC")
#' @param coverage_threshold The desired coverage threshold (default: 0.88)
#' @param plot_title Custom title for the plot
#' @param verbose Whether to print analysis summary (default: TRUE)
#'
#' @return A list containing:
#'   - coverage_data: The calculated coverage data
#'   - threshold: The inferred fold change threshold
#'   - plot: The coverage plot
#'
#' @examples
#' # Complete analysis with default FC column
#' results <- analyze_coverage(protein_data, coverage_threshold = 0.9)
#' print(results$plot)
#'
#' # Complete analysis with custom fold change column
#' results <- analyze_coverage(protein_data, fc_column = "log2FC", coverage_threshold = 0.9)
#' print(results$plot)
#'
#' @export
analyze_coverage <- function(gene_data,
                             fc_column = "FC",
                             coverage_threshold = 0.88,
                             plot_title = "Protein Fold Change Coverage Analysis",
                             verbose = TRUE) {
  # Step 1: Calculate coverage
  coverage_data <- calculate_coverage(gene_data, fc_column = fc_column)

  # Step 2: Infer threshold
  inferred_threshold <- infer_threshold(coverage_data, coverage_threshold)

  # Step 3: Create plot
  coverage_plot <- create_coverage_plot(
    coverage_data,
    coverage_threshold,
    plot_title
  )

  # Print summary if verbose
  if (verbose) {
    cat("=== COVERAGE ANALYSIS SUMMARY ===\n")
    cat("Total proteins analyzed:", sum(coverage_data$count), "\n")
    cat("Coverage threshold:", coverage_threshold * 100, "%\n")
    cat("Inferred fold change threshold:", inferred_threshold, "\n")
    cat(
      "Proteins meeting threshold:",
      sum(coverage_data$count[coverage_data$threshold <= inferred_threshold]), "\n"
    )
    cat("====================================\n")
  }

  # Return results
  return(list(
    coverage_data = coverage_data,
    threshold = inferred_threshold,
    plot = coverage_plot
  ))
}


# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

#' Identify Potential Fold Change Columns
#'
#' Helps identify columns that might contain fold change values based on
#' common naming patterns and data characteristics.
#'
#' @param gene_data A data frame containing protein expression data
#' @param show_summary Whether to show summary statistics for each candidate column
#'
#' @return A data frame with potential fold change columns and their characteristics
#'
#' @examples
#' # Find potential fold change columns
#' fc_candidates <- identify_fc_columns(protein_data)
#' print(fc_candidates)
#'
#' @export
identify_fc_columns <- function(gene_data, show_summary = TRUE) {
  if (!is.data.frame(gene_data)) {
    stop("gene_data must be a data frame")
  }

  # Common patterns for fold change column names
  fc_patterns <- c(
    "FC", "fc", "FoldChange", "fold_change", "foldchange",
    "log2FC", "log2_fc", "log2.fc", "Log2FC", "Log2_FC",
    "logFC", "log_fc", "LogFC", "Log_FC",
    "ratio", "Ratio", "fold", "Fold"
  )

  # Find columns that match common patterns
  pattern_matches <- colnames(gene_data)[colnames(gene_data) %in% fc_patterns]

  # Find columns with pattern-like names (case insensitive)
  pattern_like <- colnames(gene_data)[grepl("fc|fold|ratio", colnames(gene_data), ignore.case = TRUE)]

  # Find numeric columns that might contain fold change values
  numeric_cols <- sapply(gene_data, is.numeric)
  numeric_col_names <- names(numeric_cols)[numeric_cols]

  # Combine all candidates
  all_candidates <- unique(c(pattern_matches, pattern_like, numeric_col_names))

  if (length(all_candidates) == 0) {
    cat("No potential fold change columns found.\n")
    return(data.frame())
  }

  # Create summary for each candidate
  candidate_summary <- data.frame(
    column_name = all_candidates,
    data_type = sapply(all_candidates, function(col) class(gene_data[[col]])[1]),
    min_value = sapply(all_candidates, function(col) {
      if (is.numeric(gene_data[[col]])) round(min(gene_data[[col]], na.rm = TRUE), 3) else NA
    }),
    max_value = sapply(all_candidates, function(col) {
      if (is.numeric(gene_data[[col]])) round(max(gene_data[[col]], na.rm = TRUE), 3) else NA
    }),
    has_negative = sapply(all_candidates, function(col) {
      if (is.numeric(gene_data[[col]])) any(gene_data[[col]] < 0, na.rm = TRUE) else FALSE
    }),
    likely_log2 = sapply(all_candidates, function(col) {
      if (is.numeric(gene_data[[col]])) {
        vals <- gene_data[[col]]
        all(abs(vals) <= 15, na.rm = TRUE) && any(vals < 0, na.rm = TRUE)
      } else {
        FALSE
      }
    }),
    pattern_match = all_candidates %in% pattern_matches,
    stringsAsFactors = FALSE
  )

  # Sort by relevance (pattern matches first, then by name)
  candidate_summary <- candidate_summary[order(-candidate_summary$pattern_match, candidate_summary$column_name), ]

  if (show_summary) {
    cat("=== POTENTIAL FOLD CHANGE COLUMNS ===\n")
    cat("Found", nrow(candidate_summary), "potential columns:\n\n")
    print(candidate_summary)
    cat("\nTips:\n")
    cat("- Columns with 'pattern_match = TRUE' are most likely fold change columns\n")
    cat("- If 'likely_log2 = TRUE', the values are probably already log2 transformed\n")
    cat("- If 'has_negative = FALSE' and max_value > 10, likely linear fold change\n")
    cat("=============================================\n")
  }

  return(candidate_summary)
}


#' Export Coverage Results
#'
#' Exports coverage analysis results to files
#'
#' @param results Results from analyze_coverage()
#' @param output_dir Directory to save files (default: current directory)
#' @param file_prefix Prefix for output files
#'
#' @export
export_coverage_results <- function(results,
                                    output_dir = ".",
                                    file_prefix = "coverage_analysis") {
  # Create output directory if it doesn't exist
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Export data
  write.csv(results$coverage_data,
    file.path(output_dir, paste0(file_prefix, "_data.csv")),
    row.names = FALSE
  )

  # Export plot
  ggsave(file.path(output_dir, paste0(file_prefix, "_plot.png")),
    results$plot,
    width = 10, height = 6, dpi = 300
  )

  # Export summary
  sink(file.path(output_dir, paste0(file_prefix, "_summary.txt")))
  cat("COVERAGE ANALYSIS SUMMARY\n")
  cat("========================\n")
  cat("Generated on:", as.character(Sys.time()), "\n\n")
  cat("Total proteins analyzed:", sum(results$coverage_data$count), "\n")
  cat("Inferred fold change threshold:", results$threshold, "\n")
  cat("\nCoverage distribution:\n")
  print(results$coverage_data)
  sink()

  cat("Results exported to:", output_dir, "\n")
}