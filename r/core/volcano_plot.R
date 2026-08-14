# ==============================================================================
# PROTEOMICS VOLCANO PLOT FUNCTIONS
# ==============================================================================
# Functions for creating publication-ready volcano plots from proteomics data
#
# Features:
# - Flexible column name selection (FC, log2FC, p, p.adjust, q.value, etc.)
# - Automatic log2 transformation detection
# - Professional visualization with customizable themes
# - Intelligent gene annotation and labeling
# - Statistical summary integration
# - Export capabilities for publication
#
# Data Structure Expected:
# Your data should contain columns like: Accession, GeneName, Description, FC, p, etc.
#
# Usage Examples:
# 1. Basic volcano plot (assumes Accession, FC, p columns):
#    results <- create_volcano_plot(protein_data)
#
# 2. With gene name annotations (if data contains GeneName column):
#    results <- create_volcano_plot(protein_data, gene_annotations = protein_data)
#
# 3. Custom parameters:
#    results <- create_volcano_plot(protein_data,
#                                  fc_column = "log2FC",
#                                  p_column = "p.adjust",
#                                  fc_threshold = 1.5,
#                                  gene_annotations = protein_data)
#
# ==============================================================================

library(tidyverse)
library(dplyr)
library(ggplot2)
library(ggrepel)
library(RColorBrewer)
library(scales)

# ==============================================================================
# DATA STRUCTURE NOTES
# ==============================================================================
# Expected data structure for your proteomics data:
# - Accession: UniProt accession numbers (primary identifier)
# - GeneName: Human-readable gene names (for annotations)
# - Description: Protein descriptions (optional)
# - FC: Fold change values
# - p: P-values from statistical tests
# - Other columns: p.adjust, q.value, log2FC, etc.
#
# The functions will automatically detect if your FC values are:
# - Linear fold changes (e.g., 1.5, 2.0, 0.5)
# - Log2 fold changes (e.g., 0.58, 1.0, -1.0)
# ==============================================================================

# ==============================================================================
# DIFFERENTIAL EXPRESSION CLASSIFICATION
# ==============================================================================

#' Classify Proteins by Differential Expression
#'
#' Groups proteins into up-regulated, down-regulated, or non-significant
#' categories based on fold change and p-value thresholds.
#'
#' @param gene_data A data frame containing proteomics results
#' @param fc_column Name of the fold change column (default: "FC")
#' @param p_column Name of the p-value column (default: "p")
#' @param fc_threshold Fold change threshold for significance (default: 1.5)
#' @param p_threshold P-value threshold for significance (default: 0.05)
#' @param gene_column Name of the gene/protein identifier column (default: "Accession")
#'
#' @return The input data frame with an additional "regulation_group" column
#'
#' @examples
#' # Basic classification
#' classified_data <- classify_regulation(protein_data, fc_threshold = 1.5)
#'
#' # Custom columns and thresholds
#' classified_data <- classify_regulation(protein_data,
#'   fc_column = "log2FC",
#'   p_column = "p.adjust",
#'   fc_threshold = 2.0,
#'   p_threshold = 0.01
#' )
#'
#' @export
classify_regulation <- function(gene_data,
                                fc_column = "FC",
                                p_column = "p",
                                fc_threshold = 1.5,
                                p_threshold = 0.05,
                                gene_column = "Accession") {
  # Input validation
  if (!is.data.frame(gene_data)) {
    stop("gene_data must be a data frame")
  }

  required_cols <- c(fc_column, p_column)
  missing_cols <- setdiff(required_cols, colnames(gene_data))
  if (length(missing_cols) > 0) {
    stop(paste(
      "Missing required columns:", paste(missing_cols, collapse = ", "),
      "\nAvailable columns:", paste(colnames(gene_data), collapse = ", ")
    ))
  }

  # Validate threshold values
  if (fc_threshold <= 1) {
    stop("fc_threshold must be greater than 1")
  }

  if (p_threshold <= 0 || p_threshold >= 1) {
    stop("p_threshold must be between 0 and 1")
  }

  # Check for missing values
  if (any(is.na(gene_data[[fc_column]]))) {
    warning(paste("NA values found in", fc_column, "column"))
  }

  if (any(is.na(gene_data[[p_column]]))) {
    warning(paste("NA values found in", p_column, "column"))
  }

  # Extract fold change and p-values
  fc_values <- gene_data[[fc_column]]
  p_values <- gene_data[[p_column]]

  # Detect if fold change is log2 transformed
  if (all(abs(fc_values) <= 15, na.rm = TRUE) && any(fc_values < 0, na.rm = TRUE)) {
    message("Fold change values appear to be log2 transformed")
    log2_fc <- fc_values
    up_threshold <- log2(fc_threshold)
    down_threshold <- -log2(fc_threshold)
  } else {
    message("Converting fold change to log2 scale")
    log2_fc <- log2(fc_values)
    up_threshold <- log2(fc_threshold)
    down_threshold <- -log2(fc_threshold)
  }

  # Classify regulation groups
  gene_data$regulation_group <- case_when(
    log2_fc >= up_threshold & p_values <= p_threshold ~ "up",
    log2_fc <= down_threshold & p_values <= p_threshold ~ "down",
    TRUE ~ "no_change"
  )

  # Add log2 fold change for plotting
  gene_data$log2_fc <- log2_fc
  gene_data$neg_log10_p <- -log10(p_values)

  # Create summary statistics
  summary_stats <- gene_data %>%
    count(regulation_group) %>%
    mutate(percentage = round(n / sum(n) * 100, 1))

  # Add summary as attribute
  attr(gene_data, "regulation_summary") <- summary_stats
  attr(gene_data, "thresholds") <- list(
    fc_threshold = fc_threshold,
    p_threshold = p_threshold,
    log2_fc_threshold = up_threshold
  )

  return(gene_data)
}


# ==============================================================================
# GENE ANNOTATION PREPARATION
# ==============================================================================

#' Prepare Gene Annotations for Volcano Plot
#'
#' Selects and prepares the most significant genes for annotation on the volcano plot.
#' Uses intelligent sorting to highlight the most interesting genes.
#'
#' @param classified_data Output from classify_regulation()
#' @param gene_column Name of the gene/protein identifier column in classified_data (default: "Accession")
#' @param gene_annotations Data frame with gene name mappings (optional)
#' @param annotation_counts Named vector with counts for each group (default: c(up = 10, down = 10))
#' @param sort_method Method for selecting genes to annotate: "fc", "pvalue", or "distance" (default: "fc")
#' @param gene_id_column Column name for gene IDs in gene_annotations (default: "Accession")
#' @param gene_name_column Column name for gene names in gene_annotations (default: "GeneName")
#'
#' @return A data frame with genes selected for annotation
#'
#' @examples
#' # Basic annotation preparation
#' annotation_data <- prepare_gene_annotations(classified_data)
#'
#' # With custom gene names (data should have Accession and GeneName columns)
#' annotation_data <- prepare_gene_annotations(classified_data,
#'   gene_column = "Accession",
#'   gene_annotations = protein_data,
#'   annotation_counts = c(up = 15, down = 15)
#' )
#'
#' @export
prepare_gene_annotations <- function(classified_data,
                                     gene_column = "Accession",
                                     gene_annotations = NULL,
                                     annotation_counts = c(up = 10, down = 10),
                                     sort_method = "fc",
                                     gene_id_column = "Accession",
                                     gene_name_column = "GeneName") {
  # Input validation
  if (!"regulation_group" %in% colnames(classified_data)) {
    stop("classified_data must contain 'regulation_group' column. Run classify_regulation() first.")
  }

  if (!gene_column %in% colnames(classified_data)) {
    stop(paste(
      "Gene column", gene_column, "not found in classified_data. Available columns:",
      paste(colnames(classified_data), collapse = ", ")
    ))
  }

  # Check sort method
  if (!sort_method %in% c("fc", "pvalue", "distance")) {
    warning("Invalid sort_method. Using 'fc' instead.")
    sort_method <- "fc"
  }

  # Calculate distance from origin
  classified_data$distance <- sqrt(classified_data$log2_fc^2 + classified_data$neg_log10_p^2)

  # Select genes for annotation
  annotation_genes <- list()

  # Up-regulated genes
  if (annotation_counts["up"] > 0) {
    up_genes <- classified_data %>%
      filter(regulation_group == "up") %>%
      arrange(desc(case_when(
        sort_method == "fc" ~ abs(log2_fc),
        sort_method == "pvalue" ~ neg_log10_p,
        sort_method == "distance" ~ distance
      ))) %>%
      head(annotation_counts["up"])

    annotation_genes[["up"]] <- up_genes
  }

  # Down-regulated genes
  if (annotation_counts["down"] > 0) {
    down_genes <- classified_data %>%
      filter(regulation_group == "down") %>%
      arrange(desc(case_when(
        sort_method == "fc" ~ abs(log2_fc),
        sort_method == "pvalue" ~ neg_log10_p,
        sort_method == "distance" ~ distance
      ))) %>%
      head(annotation_counts["down"])

    annotation_genes[["down"]] <- down_genes
  }

  # Combine annotation genes
  annotation_data <- bind_rows(annotation_genes)

  # Return empty data frame if no genes selected
  if (nrow(annotation_data) == 0) {
    return(data.frame())
  }

  # Add gene names if provided
  if (!is.null(gene_annotations)) {
    if (!all(c(gene_id_column, gene_name_column) %in% colnames(gene_annotations))) {
      warning("Gene annotation columns not found. Using gene IDs instead.")
      annotation_data$display_name <- annotation_data[[gene_column]]
    } else {
      # Create proper join specification
      join_by <- setNames(gene_id_column, gene_column)
      annotation_data <- annotation_data %>%
        left_join(gene_annotations, by = join_by) %>%
        mutate(display_name = coalesce(!!sym(gene_name_column), !!sym(gene_column)))
    }
  } else {
    annotation_data$display_name <- annotation_data[[gene_column]]
  }

  return(annotation_data)
}


# ==============================================================================
# VOLCANO PLOT CREATION
# ==============================================================================

#' Create Enhanced Volcano Plot
#'
#' Creates a publication-ready volcano plot with customizable styling,
#' intelligent gene annotation, and statistical summaries.
#'
#' @param gene_data A data frame containing proteomics results
#' @param fc_column Name of the fold change column (default: "FC")
#' @param p_column Name of the p-value column (default: "p")
#' @param fc_threshold Fold change threshold for significance (default: 1.5)
#' @param p_threshold P-value threshold for significance (default: 0.05)
#' @param gene_column Name of the gene/protein identifier column (default: "Accession")
#' @param gene_annotations Data frame with gene name mappings (optional, can be same as gene_data if it contains GeneName)
#' @param annotation_counts Named vector with annotation counts (default: c(up = 10, down = 10))
#' @param sort_method Method for selecting genes to annotate (default: "fc")
#' @param title Plot title (default: auto-generated)
#' @param colors Named vector of colors for each group (optional)
#' @param point_size Size of points in the plot (default: 1.2)
#' @param alpha Point transparency (default: 0.7)
#' @param label_size Size of gene labels (default: 3)
#' @param theme_style Plot theme: "publication", "modern", or "classic" (default: "publication")
#' @param show_stats Whether to show statistical summary (default: TRUE)
#' @param xlim_symmetric Whether to make x-axis symmetric (default: TRUE)
#'
#' @return A list containing the plot and summary statistics
#'
#' @examples
#' # Basic volcano plot (assumes data has Accession, FC, p columns)
#' volcano_result <- create_volcano_plot(protein_data)
#' print(volcano_result$plot)
#'
#' # With gene name annotations (if your data has GeneName column)
#' volcano_result <- create_volcano_plot(protein_data,
#'   gene_annotations = protein_data
#' )
#'
#' # Customized volcano plot
#' volcano_result <- create_volcano_plot(protein_data,
#'   fc_column = "log2FC",
#'   p_column = "p.adjust",
#'   fc_threshold = 2.0,
#'   gene_annotations = protein_data,
#'   theme_style = "modern"
#' )
#'
#' @export
create_volcano_plot <- function(gene_data,
                                fc_column = "FC",
                                p_column = "p",
                                fc_threshold = 1.5,
                                p_threshold = 0.05,
                                gene_column = "Accession",
                                gene_annotations = NULL,
                                annotation_counts = c(up = 10, down = 10),
                                sort_method = "fc",
                                title = NULL,
                                colors = NULL,
                                point_size = 1.2,
                                alpha = 0.7,
                                label_size = 3,
                                theme_style = "publication",
                                show_stats = TRUE,
                                xlim_symmetric = TRUE) {
  # Step 1: Classify regulation groups
  classified_data <- classify_regulation(
    gene_data, fc_column, p_column,
    fc_threshold, p_threshold, gene_column
  )

  # Step 2: Prepare annotations
  annotation_data <- prepare_gene_annotations(
    classified_data, gene_column, gene_annotations,
    annotation_counts, sort_method
  )

  # Step 3: Extract summary statistics
  summary_stats <- attr(classified_data, "regulation_summary")
  thresholds <- attr(classified_data, "thresholds")

  # Step 4: Set up colors
  if (is.null(colors)) {
    colors <- c(
      "up" = "#E74C3C", # Red
      "down" = "#3498DB", # Blue
      "no_change" = "#95A5A6" # Gray
    )
  }

  # Step 5: Create title
  if (is.null(title)) {
    up_count <- summary_stats$n[summary_stats$regulation_group == "up"]
    down_count <- summary_stats$n[summary_stats$regulation_group == "down"]
    no_change_count <- summary_stats$n[summary_stats$regulation_group == "no_change"]

    if (length(up_count) == 0) up_count <- 0
    if (length(down_count) == 0) down_count <- 0
    if (length(no_change_count) == 0) no_change_count <- 0

    title <- paste0(
      "Volcano Plot: ", up_count, " Up, ", down_count, " Down, ",
      no_change_count, " No Change"
    )
  }

  # Step 6: Set axis limits
  if (xlim_symmetric) {
    max_abs_fc <- max(abs(classified_data$log2_fc), na.rm = TRUE)
    x_limits <- c(-max_abs_fc * 1.1, max_abs_fc * 1.1)
  } else {
    x_limits <- range(classified_data$log2_fc, na.rm = TRUE)
  }

  # Step 7: Create the plot
  volcano_plot <- ggplot(classified_data, aes(x = log2_fc, y = neg_log10_p)) +

    # Background points
    geom_point(aes(color = regulation_group),
      size = point_size,
      alpha = alpha
    ) +

    # Threshold lines
    geom_hline(
      yintercept = -log10(p_threshold),
      linetype = "dashed",
      color = "gray40",
      linewidth = 0.5
    ) +
    geom_vline(
      xintercept = c(-thresholds$log2_fc_threshold, thresholds$log2_fc_threshold),
      linetype = "dashed",
      color = "gray40",
      linewidth = 0.5
    ) +

    # Gene labels
    {
      if (nrow(annotation_data) > 0) {
        geom_text_repel(
          data = annotation_data,
          aes(label = display_name),
          size = label_size,
          color = "black",
          bg.color = "white",
          bg.r = 0.1,
          segment.color = "gray30",
          segment.size = 0.3,
          min.segment.length = 0.1,
          max.overlaps = 20,
          force = 2,
          seed = 42
        )
      }
    } +

    # Scales and labels
    scale_color_manual(
      values = colors,
      name = "Regulation",
      labels = c(
        "down" = "Down-regulated",
        "no_change" = "No change",
        "up" = "Up-regulated"
      )
    ) +
    scale_x_continuous(
      name = bquote(log[2] ~ "(Fold Change)"),
      limits = x_limits,
      breaks = pretty_breaks(n = 8)
    ) +
    scale_y_continuous(
      name = bquote(-log[10] ~ "(P-value)"),
      breaks = pretty_breaks(n = 6),
      expand = expansion(add = c(0.1, 0.3))
    ) +
    labs(
      title = title,
      subtitle = paste0(
        "log2FC threshold: ±", log2(fc_threshold),
        ", P-value threshold: ", p_threshold
      )
    ) +

    # Apply theme
    {
      if (theme_style == "publication") {
        list(
          theme_classic(),
          theme(
            plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
            plot.subtitle = element_text(size = 12, hjust = 0.5, color = "gray60"),
            axis.title = element_text(size = 12, face = "bold"),
            axis.text = element_text(size = 10),
            legend.title = element_text(size = 11, face = "bold"),
            legend.text = element_text(size = 10),
            legend.position = "bottom",
            panel.grid.major = element_line(color = "gray90", size = 0.3),
            panel.grid.minor = element_blank(),
            plot.margin = margin(t = 20, r = 20, b = 20, l = 20)
          )
        )
      } else if (theme_style == "modern") {
        list(
          theme_minimal(),
          theme(
            plot.title = element_text(size = 16, face = "bold", hjust = 0.5),
            plot.subtitle = element_text(size = 13, hjust = 0.5, color = "gray60"),
            axis.title = element_text(size = 13, face = "bold"),
            axis.text = element_text(size = 11),
            legend.title = element_text(size = 12, face = "bold"),
            legend.text = element_text(size = 11),
            legend.position = "right",
            panel.grid.minor = element_blank(),
            plot.background = element_rect(fill = "white", color = NA),
            plot.margin = margin(t = 25, r = 25, b = 25, l = 25)
          )
        )
      } else {
        list(
          theme_bw(),
          theme(
            plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
            plot.subtitle = element_text(size = 12, hjust = 0.5),
            axis.title = element_text(size = 12),
            axis.text = element_text(size = 10),
            legend.position = "bottom",
            panel.grid.minor = element_blank()
          )
        )
      }
    }

  # Step 8: Add statistical annotation if requested
  if (show_stats) {
    # Add text annotation with statistics
    stats_text <- paste0(
      "Up: ", sum(summary_stats$n[summary_stats$regulation_group == "up"], na.rm = TRUE),
      " (", sum(summary_stats$percentage[summary_stats$regulation_group == "up"], na.rm = TRUE), "%)\n",
      "Down: ", sum(summary_stats$n[summary_stats$regulation_group == "down"], na.rm = TRUE),
      " (", sum(summary_stats$percentage[summary_stats$regulation_group == "down"], na.rm = TRUE), "%)\n",
      "No change: ", sum(summary_stats$n[summary_stats$regulation_group == "no_change"], na.rm = TRUE),
      " (", sum(summary_stats$percentage[summary_stats$regulation_group == "no_change"], na.rm = TRUE), "%)"
    )

    volcano_plot <- volcano_plot +
      annotate("text",
        x = x_limits[1] + 0.05 * diff(x_limits),
        y = max(classified_data$neg_log10_p, na.rm = TRUE) * 0.95,
        label = stats_text,
        hjust = 0, vjust = 1,
        size = 3, color = "gray40",
        fontface = "italic"
      )
  }

  # Return results
  return(list(
    plot = volcano_plot,
    data = classified_data,
    annotations = annotation_data,
    summary = summary_stats,
    thresholds = thresholds
  ))
}


# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

#' Identify Potential Columns for Volcano Plot
#'
#' Helps identify columns that might contain fold change values, p-values,
#' or gene identifiers based on common naming patterns.
#'
#' @param gene_data A data frame containing proteomics results
#' @param show_summary Whether to show summary statistics (default: TRUE)
#'
#' @return A list with potential columns for each data type
#'
#' @examples
#' # Identify potential columns
#' column_candidates <- identify_volcano_columns(protein_data)
#'
#' @export
identify_volcano_columns <- function(gene_data, show_summary = TRUE) {
  if (!is.data.frame(gene_data)) {
    stop("gene_data must be a data frame")
  }

  # Fold change patterns
  fc_patterns <- c(
    "FC", "fc", "FoldChange", "fold_change", "foldchange",
    "log2FC", "log2_fc", "log2.fc", "Log2FC", "Log2_FC",
    "logFC", "log_fc", "LogFC", "Log_FC",
    "ratio", "Ratio", "fold", "Fold"
  )

  # P-value patterns
  p_patterns <- c(
    "p", "P", "pval", "pvalue", "p.value", "P.Value",
    "p.adjust", "p_adjust", "padj", "P.adj", "adj.P.Val",
    "q", "Q", "qval", "qvalue", "q.value", "Q.Value",
    "fdr", "FDR", "BH", "bonferroni"
  )

  # Gene identifier patterns
  gene_patterns <- c(
    "Accession", "accession", "ACCESSION",
    "GeneName", "gene_name", "GeneSymbol", "gene_symbol",
    "Protein", "protein", "ProteinID", "protein_id",
    "UniProt", "uniprot", "UniProtKB", "uniprotkb",
    "ID", "id", "Identifier", "identifier",
    "Description", "description", "DESCRIPTION"
  )

  # Find matching columns
  fc_candidates <- colnames(gene_data)[colnames(gene_data) %in% fc_patterns |
    grepl("fc|fold|ratio", colnames(gene_data), ignore.case = TRUE)]

  p_candidates <- colnames(gene_data)[colnames(gene_data) %in% p_patterns |
    grepl("p|q|fdr|adj", colnames(gene_data), ignore.case = TRUE)]

  gene_candidates <- colnames(gene_data)[colnames(gene_data) %in% gene_patterns |
    grepl("gene|protein|id|accession|symbol", colnames(gene_data), ignore.case = TRUE)]

  # Create summary
  candidates <- list(
    fold_change = fc_candidates,
    p_value = p_candidates,
    gene_id = gene_candidates
  )

  if (show_summary) {
    cat("=== VOLCANO PLOT COLUMN CANDIDATES ===\n")
    cat("Fold Change columns:", paste(fc_candidates, collapse = ", "), "\n")
    cat("P-value columns:", paste(p_candidates, collapse = ", "), "\n")
    cat("Gene ID columns:", paste(gene_candidates, collapse = ", "), "\n")
    cat("\nRecommended usage:\n")
    cat("create_volcano_plot(data, fc_column = '", fc_candidates[1], "', p_column = '", p_candidates[1], "')\n")
    cat("=========================================\n")
  }

  return(candidates)
}


#' Export Volcano Plot Results
#'
#' Exports volcano plot results including the plot, data, and summary statistics.
#'
#' @param volcano_results Results from create_volcano_plot()
#' @param output_dir Directory to save files (default: current directory)
#' @param file_prefix Prefix for output files (default: "volcano_plot")
#' @param plot_format Format for plot export: "png", "pdf", "svg" (default: "png")
#' @param plot_width Plot width in inches (default: 10)
#' @param plot_height Plot height in inches (default: 8)
#' @param dpi Plot resolution (default: 300)
#'
#' @export
export_volcano_results <- function(volcano_results,
                                   output_dir = ".",
                                   file_prefix = "volcano_plot",
                                   plot_format = "png",
                                   plot_width = 10,
                                   plot_height = 8,
                                   dpi = 300) {
  # Create output directory if it doesn't exist
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Export plot
  plot_file <- file.path(output_dir, paste0(file_prefix, ".", plot_format))
  ggsave(plot_file, volcano_results$plot,
    width = plot_width, height = plot_height, dpi = dpi
  )

  # Export data
  write.csv(volcano_results$data,
    file.path(output_dir, paste0(file_prefix, "_data.csv")),
    row.names = FALSE
  )

  # Export annotations
  if (nrow(volcano_results$annotations) > 0) {
    write.csv(volcano_results$annotations,
      file.path(output_dir, paste0(file_prefix, "_annotations.csv")),
      row.names = FALSE
    )
  }

  # Export summary
  sink(file.path(output_dir, paste0(file_prefix, "_summary.txt")))
  cat("VOLCANO PLOT ANALYSIS SUMMARY\n")
  cat("=============================\n")
  cat("Generated on:", as.character(Sys.time()), "\n\n")
  cat("Thresholds:\n")
  cat("- Fold change threshold:", volcano_results$thresholds$fc_threshold, "\n")
  cat("- P-value threshold:", volcano_results$thresholds$p_threshold, "\n")
  cat("- Log2 fold change threshold: ±", volcano_results$thresholds$log2_fc_threshold, "\n\n")
  cat("Results summary:\n")
  print(volcano_results$summary)
  sink()

  cat("Volcano plot results exported to:", output_dir, "\n")
}

# ==============================================================================
# USAGE EXAMPLES
# ==============================================================================
# Here are some practical examples for your data structure:
#
# # Example 1: Basic volcano plot (assumes Accession, FC, p columns)
# results <- create_volcano_plot(protein_data)
# print(results$plot)
#
# # Example 2: With gene name annotations
# results <- create_volcano_plot(protein_data,
#                               gene_annotations = protein_data)
# print(results$plot)
#
# # Example 3: Custom thresholds and parameters
# results <- create_volcano_plot(protein_data,
#                               fc_column = "FC",
#                               p_column = "p.adjust",
#                               fc_threshold = 1.5,
#                               p_threshold = 0.01,
#                               gene_annotations = protein_data,
#                               annotation_counts = c(up = 15, down = 15),
#                               theme_style = "modern")
#
# # Example 4: Export results
# export_volcano_results(results, output_dir = "volcano_results/")
#
# # Example 5: Find potential columns first
# candidates <- identify_volcano_columns(protein_data)
# results <- create_volcano_plot(protein_data,
#                               fc_column = candidates$fold_change[1],
#                               p_column = candidates$p_value[1])
# ==============================================================================