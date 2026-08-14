# ==============================================================================
# PROTEOMICS GSEA ANALYSIS FUNCTIONS
# ==============================================================================
# Enhanced functions for Gene Set Enrichment Analysis (GSEA) with modern features
#
# Features:
# - Modern progress bars with progress package
# - Flexible parameter control
# - Professional visualization with customizable themes
# - Automatic file name sanitization
# - Comprehensive error handling
# - Batch processing capabilities
# - Export in multiple formats
# - Memory-efficient processing
#
# Data Structure Expected:
# - gene_data: Data frame with Gene, FC, and p-value columns
# - term2gene: Two-column data frame (pathway ID, gene ID)
# - term2name: Two-column data frame (pathway ID, pathway name)
#
# Usage Examples:
# 1. Basic GSEA:
#    gsea_results <- run_gsea_analysis(gene_data, term2gene, term2name)
#
# 2. With custom parameters:
#    gsea_results <- run_gsea_analysis(gene_data, term2gene, term2name,
#                                     fc_column = "log2FC", p_column = "p.adjust")
#
# 3. Complete workflow with plots:
#    results <- run_gsea_workflow(gene_data, term2gene, term2name,
#                                output_dir = "gsea_results/")
#
# ==============================================================================

library(clusterProfiler)
library(tidyverse)
library(enrichplot)
library(ggplot2)
library(progress)
library(stringr)
library(scales)
library(RColorBrewer)
library(patchwork)

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

#' Sanitize File Names
#'
#' Cleans file names by removing or replacing invalid characters.
#'
#' @param filename Character vector of file names to sanitize
#' @param replacement Character to replace invalid characters (default: "_")
#' @param max_length Maximum length of filename (default: 100)
#'
#' @return Character vector of sanitized file names
#'
#' @examples
#' sanitize_filename("Pathway / with special chars: <test>")
#'
#' @export
sanitize_filename <- function(filename, replacement = "_", max_length = 100) {
  # Remove or replace invalid characters
  filename <- str_replace_all(filename, "[<>:\"/\\|?*]", replacement)

  # Replace multiple consecutive replacement characters with single one
  filename <- str_replace_all(filename, paste0(replacement, "+"), replacement)

  # Remove leading/trailing replacement characters
  filename <- str_replace_all(filename, paste0("^", replacement, "+|", replacement, "+$"), "")

  # Truncate if too long
  if (nchar(filename) > max_length) {
    filename <- paste0(substr(filename, 1, max_length - 3), "...")
  }

  return(filename)
}


#' Validate GSEA Input Data
#'
#' Validates and prepares gene data for GSEA analysis.
#'
#' @param gene_data Data frame containing gene expression data
#' @param gene_column Name of the gene column (default: "Gene")
#' @param fc_column Name of the fold change column (default: "FC")
#' @param p_column Name of the p-value column (default: "p")
#'
#' @return Validated and standardized gene data
#'
#' @export
validate_gsea_input <- function(gene_data,
                                gene_column = "Gene",
                                fc_column = "FC",
                                p_column = "p") {
  # Check if required columns exist
  required_cols <- c(gene_column, fc_column, p_column)
  missing_cols <- setdiff(required_cols, colnames(gene_data))

  if (length(missing_cols) > 0) {
    stop(paste(
      "Missing required columns:", paste(missing_cols, collapse = ", "),
      "\nAvailable columns:", paste(colnames(gene_data), collapse = ", ")
    ))
  }

  # Remove rows with NA values
  initial_rows <- nrow(gene_data)
  gene_data <- gene_data[complete.cases(gene_data[, required_cols]), ]

  if (nrow(gene_data) < initial_rows) {
    message(paste("Removed", initial_rows - nrow(gene_data), "rows with NA values"))
  }

  # Check for duplicate genes
  if (any(duplicated(gene_data[[gene_column]]))) {
    warning("Duplicate genes found. Using the first occurrence of each gene.")
    gene_data <- gene_data[!duplicated(gene_data[[gene_column]]), ]
  }

  # Validate fold change values
  fc_values <- gene_data[[fc_column]]
  if (any(is.infinite(fc_values))) {
    warning("Infinite fold change values found. These will be removed.")
    gene_data <- gene_data[!is.infinite(fc_values), ]
  }

  # Validate p-values
  p_values <- gene_data[[p_column]]
  if (any(p_values < 0 | p_values > 1)) {
    warning("P-values outside [0,1] range found. Please check your data.")
  }

  return(gene_data)
}


#' Prepare Gene List for GSEA
#'
#' Prepares a ranked gene list for GSEA analysis with proper sorting.
#'
#' @param gene_data Validated gene data from validate_gsea_input()
#' @param gene_column Name of the gene column (default: "Gene")
#' @param fc_column Name of the fold change column (default: "FC")
#' @param p_column Name of the p-value column (default: "p")
#' @param p_threshold P-value threshold for gene filtering (default: 1, no filtering)
#' @param ranking_method Method for ranking genes: "fc", "signed_p", or "combined" (default: "fc")
#'
#' @return Named numeric vector of gene scores
#'
#' @export
prepare_gene_list <- function(gene_data,
                              gene_column = "Gene",
                              fc_column = "FC",
                              p_column = "p",
                              p_threshold = 1,
                              ranking_method = c("fc", "signed_p", "combined")) {
  ranking_method <- match.arg(ranking_method)

  # Filter by p-value if specified
  if (p_threshold < 1) {
    gene_data <- gene_data[gene_data[[p_column]] <= p_threshold, ]
    message(paste("Filtered to", nrow(gene_data), "genes with p <=", p_threshold))
  }

  # Extract values
  genes <- gene_data[[gene_column]]
  fc_values <- gene_data[[fc_column]]
  p_values <- gene_data[[p_column]]

  # Convert fold change to log2 if needed
  if (all(fc_values > 0) && any(fc_values != 1)) {
    # Check if values look like linear fold changes
    if (any(fc_values > 10) || all(fc_values >= 0.1)) {
      message("Converting fold change to log2 scale")
      fc_values <- log2(fc_values)
    }
  }

  # Calculate ranking scores based on method
  if (ranking_method == "fc") {
    scores <- fc_values
  } else if (ranking_method == "signed_p") {
    # -log10(p) * sign(log2FC)
    scores <- -log10(p_values) * sign(fc_values)
  } else if (ranking_method == "combined") {
    # Combine fold change and p-value
    scores <- fc_values * (-log10(p_values))
  }

  # Create named vector
  names(scores) <- genes

  # Sort in decreasing order
  scores <- sort(scores, decreasing = TRUE)

  return(scores)
}


# ==============================================================================
# GSEA ANALYSIS FUNCTIONS
# ==============================================================================

#' Run Enhanced GSEA Analysis
#'
#' Performs Gene Set Enrichment Analysis with comprehensive options and validation.
#'
#' @param gene_data Data frame containing gene expression data
#' @param term2gene Two-column data frame mapping pathway IDs to gene IDs
#' @param term2name Two-column data frame mapping pathway IDs to pathway names
#' @param gene_column Name of the gene column (default: "Gene")
#' @param fc_column Name of the fold change column (default: "FC")
#' @param p_column Name of the p-value column (default: "p")
#' @param p_threshold P-value threshold for gene filtering (default: 1)
#' @param ranking_method Method for ranking genes (default: "fc")
#' @param gsea_pvalue_cutoff P-value cutoff for GSEA (default: 0.05)
#' @param gsea_qvalue_cutoff Q-value cutoff for GSEA (default: 0.2)
#' @param min_gs_size Minimum gene set size (default: 10)
#' @param max_gs_size Maximum gene set size (default: 500)
#' @param nperm Number of permutations (default: 1000)
#' @param seed Random seed for reproducibility (default: 42)
#' @param verbose Whether to show progress messages (default: TRUE)
#'
#' @return gseaResult object from clusterProfiler
#'
#' @examples
#' gsea_results <- run_gsea_analysis(gene_data, term2gene, term2name)
#'
#' @export
run_gsea_analysis <- function(gene_data,
                              term2gene,
                              term2name,
                              gene_column = "Gene",
                              fc_column = "FC",
                              p_column = "p",
                              p_threshold = 0.05,
                              ranking_method = "fc",
                              gsea_pvalue_cutoff = 1,
                              gsea_qvalue_cutoff = 1,
                              min_gs_size = 10,
                              max_gs_size = 500,
                              nperm = 1000,
                              seed = 42,
                              verbose = TRUE) {
  if (verbose) cat("Starting GSEA analysis...\n")

  # Validate input data
  gene_data <- validate_gsea_input(gene_data, gene_column, fc_column, p_column)

  # Prepare gene list
  gene_list <- prepare_gene_list(
    gene_data, gene_column, fc_column, p_column,
    p_threshold, ranking_method
  )

  if (verbose) {
    cat("Prepared gene list with", length(gene_list), "genes\n")
    cat("Range of scores:", round(range(gene_list), 3), "\n")
  }

  # Validate term2gene and term2name
  if (ncol(term2gene) != 2) {
    stop("term2gene must have exactly 2 columns")
  }
  if (ncol(term2name) != 2) {
    stop("term2name must have exactly 2 columns")
  }

  # Set seed for reproducibility
  set.seed(seed)

  # Run GSEA
  if (verbose) cat("Running GSEA enrichment...\n")

  gsea_result <- tryCatch(
    {
      GSEA(
        geneList = gene_list,
        TERM2GENE = term2gene,
        TERM2NAME = term2name,
        pvalueCutoff = gsea_pvalue_cutoff,
        pAdjustMethod = "BH",
        minGSSize = min_gs_size,
        maxGSSize = max_gs_size,
        eps = 1e-10,
        nPermSimple = nperm,
        verbose = verbose
      )
    },
    error = function(e) {
      stop(paste("GSEA analysis failed:", e$message))
    }
  )

  if (verbose) {
    n_significant <- sum(gsea_result@result$qvalue < gsea_qvalue_cutoff)
    cat("GSEA completed! Found", n_significant, "significant gene sets\n")
  }

  return(gsea_result)
}


# ==============================================================================
# VISUALIZATION FUNCTIONS
# ==============================================================================

#' Create Enhanced Ridge Plot
#'
#' Creates a publication-ready ridge plot for GSEA results.
#'
#' @param gsea_result gseaResult object from run_gsea_analysis()
#' @param show_category Number of categories to show (default: 20)
#' @param order_by Column to order by (default: "qvalue")
#' @param decreasing Whether to order in decreasing order (default: FALSE)
#' @param title Plot title (default: "GSEA Ridge Plot")
#' @param colors Color palette for the plot (optional)
#' @param font_size Base font size (default: 12)
#'
#' @return ggplot object
#'
#' @examples
#' ridge_plot <- create_ridge_plot(gsea_results, show_category = 30)
#'
#' @export
create_ridge_plot <- function(gsea_result,
                              show_category = 20,
                              order_by = "qvalue",
                              decreasing = FALSE,
                              title = "GSEA Ridge Plot",
                              colors = NULL,
                              font_size = 12) {
  if (nrow(gsea_result@result) == 0) {
    stop("No GSEA results to plot")
  }

  # Create base ridge plot
  p <- tryCatch(
    {
      ridgeplot(gsea_result,
        showCategory = show_category,
        orderBy = order_by,
        decreasing = decreasing
      ) +

        labs(
          title = title,
          x = "Gene Rank",
          y = "Pathways"
        ) +

        theme_minimal() +
        theme(
          plot.title = element_text(size = font_size * 1.2, face = "bold", hjust = 0.5),
          axis.title = element_text(size = font_size, face = "bold"),
          axis.text = element_text(size = font_size * 0.9),
          axis.text.y = element_text(hjust = 0),
          legend.title = element_text(size = font_size, face = "bold"),
          legend.text = element_text(size = font_size * 0.9),
          panel.grid.minor = element_blank(),
          plot.margin = margin(t = 20, r = 20, b = 20, l = 20)
        )
    },
    error = function(e) {
      warning(paste("Ridge plot failed:", e$message))
      return(NULL)
    }
  )

  return(p)
}


#' Create Enhanced GSEA Plots
#'
#' Creates individual GSEA plots for each significant pathway with modern styling.
#'
#' @param gsea_result gseaResult object from run_gsea_analysis()
#' @param output_dir Directory to save plots
#' @param q_threshold Q-value threshold for plotting (default: 0.05)
#' @param max_plots Maximum number of plots to generate (default: 50)
#' @param plot_formats Vector of plot formats to save (default: c("pdf", "png"))
#' @param plot_width Plot width in inches (default: 10)
#' @param plot_height Plot height in inches (default: 6)
#' @param base_size Base font size for plots (default: 12)
#' @param show_progress Whether to show progress bar (default: TRUE)
#' @param dpi Resolution for raster formats (default: 300)
#'
#' @return List of ggplot objects
#'
#' @examples
#' gsea_plots <- create_gsea_plots(gsea_results, "output/gsea_plots/")
#'
#' @export
create_gsea_plots <- function(gsea_result,
                              output_dir,
                              q_threshold = 0.05,
                              max_plots = 30,
                              plot_formats = c("pdf", "png"),
                              plot_width = 10,
                              plot_height = 6,
                              base_size = 12,
                              show_progress = TRUE,
                              dpi = 300) {
  # Get significant results
  gsea_df <- gsea_result@result
  significant_results <- gsea_df[gsea_df$qvalue < q_threshold, ]

  if (nrow(significant_results) == 0) {
    warning("No significant results to plot")
    return(list())
  }

  # Remove pathways with NA values that can cause plotting issues
  significant_results <- significant_results[!is.na(significant_results$enrichmentScore) &
    !is.na(significant_results$NES) &
    !is.na(significant_results$qvalue), ]

  if (nrow(significant_results) == 0) {
    warning("No valid results to plot after filtering NA values")
    return(list())
  }

  # Limit number of plots
  if (nrow(significant_results) > max_plots) {
    warning(paste("Limiting to", max_plots, "plots (out of", nrow(significant_results), "significant results)"))
    significant_results <- head(significant_results, max_plots)
  }

  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Initialize progress bar
  if (show_progress) {
    pb <- progress_bar$new(
      format = "Creating GSEA plots [:bar] :percent (:current/:total) ETA: :eta",
      total = nrow(significant_results),
      clear = FALSE,
      width = 80
    )
  }

  # Generate plots
  plots <- list()
  successful_plots <- 0

  for (i in 1:nrow(significant_results)) {
    if (show_progress) pb$tick()

    pathway <- significant_results[i, ]
    pathway_id <- pathway$ID
    pathway_name <- pathway$Description

    # Validate pathway data
    if (is.na(pathway_id) || is.na(pathway_name)) {
      warning(paste("Skipping pathway with missing ID or name:", pathway_id))
      next
    }

    # Create plot title with statistics
    plot_title <- paste0(pathway_id, ": ", pathway_name)
    plot_subtitle <- paste0(
      "ES: ", round(pathway$enrichmentScore, 3),
      ", NES: ", round(pathway$NES, 3),
      ", q-value: ", scientific(pathway$qvalue, digits = 3)
    )

    # Try multiple approaches to create GSEA plot
    gsea_plot <- NULL

    # Method 1: Try gseaplot2 with basic parameters
    if (is.null(gsea_plot)) {
      gsea_plot <- tryCatch(
        {
          gseaplot2(gsea_result,
            geneSetID = pathway_id,
            title = plot_title,
            pvalue_table = FALSE,
            base_size = base_size
          )
        },
        error = function(e) {
          if (show_progress) cat(paste("\nMethod 1 failed for", pathway_id, ":", e$message, "\n"))
          return(NULL)
        }
      )
    }

    # Method 2: Try with single subplot
    if (is.null(gsea_plot)) {
      gsea_plot <- tryCatch(
        {
          gseaplot2(gsea_result,
            geneSetID = pathway_id,
            title = plot_title,
            subplots = 1,
            pvalue_table = FALSE,
            base_size = base_size
          )
        },
        error = function(e) {
          if (show_progress) cat(paste("\nMethod 2 failed for", pathway_id, ":", e$message, "\n"))
          return(NULL)
        }
      )
    }

    # Method 3: Try the original gseaplot function
    if (is.null(gsea_plot)) {
      gsea_plot <- tryCatch(
        {
          gseaplot(gsea_result,
            geneSetID = pathway_id,
            title = plot_title,
            by = "runningScore"
          ) +
            theme(plot.title = element_text(size = base_size * 1.1, face = "bold"))
        },
        error = function(e) {
          if (show_progress) cat(paste("\nMethod 3 failed for", pathway_id, ":", e$message, "\n"))
          return(NULL)
        }
      )
    }

    # Method 4: Create a simple custom plot
    if (is.null(gsea_plot)) {
      gsea_plot <- tryCatch(
        {
          # Create a simple text plot as fallback
          ggplot() +
            annotate("text",
              x = 0.5, y = 0.5,
              label = paste(
                "Plot generation failed for:\n",
                plot_title, "\n\n", plot_subtitle
              ),
              size = 4, hjust = 0.5, vjust = 0.5
            ) +
            theme_void() +
            theme(plot.margin = margin(20, 20, 20, 20))
        },
        error = function(e) {
          if (show_progress) cat(paste("\nAll methods failed for", pathway_id, "\n"))
          return(NULL)
        }
      )
    }

    if (!is.null(gsea_plot)) {
      successful_plots <- successful_plots + 1
      plots[[pathway_id]] <- gsea_plot

      # Add subtitle if the plot was created successfully
      if ("ggplot" %in% class(gsea_plot)) {
        gsea_plot <- gsea_plot + labs(subtitle = plot_subtitle)
      }

      # Save plots in requested formats
      safe_filename <- sanitize_filename(paste0(pathway_id, "_", pathway_name))

      for (format in plot_formats) {
        filename <- file.path(output_dir, paste0(safe_filename, ".", format))

        tryCatch(
          {
            ggsave(filename, gsea_plot,
              width = plot_width, height = plot_height, dpi = dpi
            )
          },
          error = function(e) {
            warning(paste("Failed to save", format, "plot for", pathway_id, ":", e$message))
          }
        )
      }
    } else {
      warning(paste("All plot generation methods failed for pathway:", pathway_id))
    }
  }

  if (show_progress) {
    cat("\nGSEA plots completed!\n")
    cat("Generated", successful_plots, "out of", nrow(significant_results), "plots in", output_dir, "\n")
  }

  return(plots)
}


#' Create GSEA Summary Plot
#'
#' Creates a summary visualization of GSEA results.
#'
#' @param gsea_result gseaResult object from run_gsea_analysis()
#' @param top_n Number of top pathways to show (default: 20)
#' @param title Plot title (default: "GSEA Summary")
#' @param font_size Base font size (default: 12)
#'
#' @return ggplot object
#'
#' @examples
#' summary_plot <- create_gsea_summary_plot(gsea_results)
#'
#' @export
create_gsea_summary_plot <- function(gsea_result,
                                     top_n = 20,
                                     title = "GSEA Summary",
                                     font_size = 12) {
  gsea_df <- gsea_result@result

  if (nrow(gsea_df) == 0) {
    stop("No GSEA results to plot")
  }

  # Select top results
  plot_data <- head(gsea_df, top_n)

  # Wrap pathway names for better display
  plot_data$Description_wrapped <- str_wrap(plot_data$Description, width = 40)

  # Create factor for ordering
  plot_data$Description_wrapped <- factor(
    plot_data$Description_wrapped,
    levels = rev(plot_data$Description_wrapped)
  )

  # Create dot plot
  p <- ggplot(plot_data, aes(y = Description_wrapped)) +
    geom_point(aes(
      x = NES,
      size = abs(enrichmentScore),
      color = qvalue
    )) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "gray50") +
    scale_color_gradient(
      low = "#E74C3C", high = "#3498DB",
      name = "Q-value",
      trans = "log10",
      labels = scientific_format()
    ) +
    scale_size_continuous(
      name = "|ES|",
      range = c(3, 8),
      breaks = pretty_breaks(n = 4)
    ) +
    labs(
      title = title,
      x = "Normalized Enrichment Score (NES)",
      y = NULL
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = font_size * 1.2, face = "bold", hjust = 0.5),
      axis.title = element_text(size = font_size, face = "bold"),
      axis.text = element_text(size = font_size * 0.9),
      axis.text.y = element_text(hjust = 0),
      legend.title = element_text(size = font_size, face = "bold"),
      legend.text = element_text(size = font_size * 0.8),
      panel.grid.minor = element_blank(),
      panel.grid.major.y = element_blank(),
      plot.margin = margin(t = 20, r = 20, b = 20, l = 20)
    )

  return(p)
}


# ==============================================================================
# COMPREHENSIVE WORKFLOW FUNCTIONS
# ==============================================================================

#' Run Complete GSEA Workflow
#'
#' Performs complete GSEA analysis workflow including analysis, visualization, and export.
#'
#' @param gene_data Data frame containing gene expression data
#' @param term2gene Two-column data frame mapping pathway IDs to gene IDs
#' @param term2name Two-column data frame mapping pathway IDs to pathway names
#' @param output_dir Directory to save results
#' @param file_prefix Prefix for output files (default: "gsea")
#' @param gene_column Name of the gene column (default: "Gene")
#' @param fc_column Name of the fold change column (default: "FC")
#' @param p_column Name of the p-value column (default: "p")
#' @param gsea_qvalue_cutoff Q-value cutoff for significance (default: 0.05)
#' @param create_plots Whether to create individual pathway plots (default: TRUE)
#' @param plot_formats Vector of plot formats (default: c("pdf", "png"))
#' @param verbose Whether to show progress messages (default: TRUE)
#'
#' @return List with GSEA results, plots, and summary statistics
#'
#' @examples
#' results <- run_gsea_workflow(gene_data, term2gene, term2name,
#'   output_dir = "gsea_results/"
#' )
#'
#' @export
run_gsea_workflow <- function(gene_data,
                              term2gene,
                              term2name,
                              output_dir,
                              file_prefix = "gsea",
                              gene_column = "Gene",
                              fc_column = "FC",
                              p_column = "p",
                              gene_pvalue_cutoff = 0.05,
                              gsea_qvalue_cutoff = 1,
                              create_plots = TRUE,
                              plot_formats = c("pdf", "png"),
                              verbose = TRUE) {
  if (verbose) cat("Starting GSEA workflow...\n")

  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Run GSEA analysis
  gsea_result <- run_gsea_analysis(
    gene_data = gene_data,
    term2gene = term2gene,
    term2name = term2name,
    gene_column = gene_column,
    fc_column = fc_column,
    p_column = p_column,
    p_threshold = gene_pvalue_cutoff,
    gsea_qvalue_cutoff = gsea_qvalue_cutoff,
    verbose = verbose
  )

  # Export results
  if (verbose) cat("Exporting GSEA results...\n")
  write.csv(gsea_result@result,
    file.path(output_dir, paste0(file_prefix, "_results.csv")),
    row.names = FALSE
  )

  # Create summary plots
  plots <- list()

  if (nrow(gsea_result@result) > 0) {
    # Ridge plot
    if (verbose) cat("Creating ridge plot...\n")
    tryCatch(
      {
        ridge_plot <- create_ridge_plot(gsea_result)
        if (!is.null(ridge_plot)) {
          plots$ridge_plot <- ridge_plot
          ggsave(file.path(output_dir, paste0(file_prefix, "_ridge_plot.pdf")),
            ridge_plot,
            width = 12, height = 8, dpi = 300
          )
        }
      },
      error = function(e) {
        warning(paste("Ridge plot failed:", e$message))
      }
    )

    # Summary plot
    if (verbose) cat("Creating summary plot...\n")
    tryCatch(
      {
        summary_plot <- create_gsea_summary_plot(gsea_result)
        plots$summary_plot <- summary_plot
        ggsave(file.path(output_dir, paste0(file_prefix, "_summary_plot.pdf")),
          summary_plot,
          width = 10, height = 8, dpi = 300
        )
      },
      error = function(e) {
        warning(paste("Summary plot failed:", e$message))
      }
    )

    # Individual pathway plots
    if (create_plots) {
      if (verbose) cat("Creating individual pathway plots...\n")
      pathway_plots_dir <- file.path(output_dir, "pathway_plots")
      pathway_plots <- create_gsea_plots(
        gsea_result = gsea_result,
        output_dir = pathway_plots_dir,
        q_threshold = gsea_qvalue_cutoff,
        plot_formats = plot_formats,
        show_progress = verbose
      )
      plots$pathway_plots <- pathway_plots
    }
  }

  # Create summary statistics
  summary_stats <- list(
    total_pathways = nrow(gsea_result@result),
    significant_pathways = sum(gsea_result@result$qvalue < gsea_qvalue_cutoff),
    input_genes = length(gsea_result@geneList),
    analysis_parameters = list(
      gene_column = gene_column,
      fc_column = fc_column,
      p_column = p_column,
      qvalue_cutoff = gsea_qvalue_cutoff
    )
  )

  # Set significant_pathways to 0 if missing (i.e., no significant pathways found)
  summary_stats$significant_pathways <- ifelse(
    is.na(summary_stats$significant_pathways),
    0,
    summary_stats$significant_pathways
  )

  # Export summary
  writeLines(
    c(
      "GSEA Analysis Summary",
      "====================",
      paste("Analysis date:", Sys.time()),
      paste("Total pathways tested:", summary_stats$total_pathways),
      paste("Significant pathways:", summary_stats$significant_pathways),
      paste("Input genes:", summary_stats$input_genes),
      paste("Q-value cutoff:", gsea_qvalue_cutoff),
      "",
      "Top 10 Significant Pathways:",
      "----------------------------"
    ),
    file.path(output_dir, paste0(file_prefix, "_summary.txt"))
  )

  # Add top pathways to summary
  if (summary_stats$significant_pathways > 0) {
    top_pathways <- head(gsea_result@result[
      gsea_result@result$qvalue < gsea_qvalue_cutoff,
      c("Description", "NES", "qvalue")
    ], 10)
    write.table(top_pathways,
      file.path(output_dir, paste0(file_prefix, "_summary.txt")),
      append = TRUE, sep = "\t", row.names = FALSE
    )
  }

  if (verbose) {
    cat("GSEA workflow completed!\n")
    cat("Results saved to:", output_dir, "\n")
    cat("Total pathways:", summary_stats$total_pathways, "\n")
    cat("Significant pathways:", summary_stats$significant_pathways, "\n")
  }

  return(list(
    gsea_result = gsea_result,
    plots = plots,
    summary = summary_stats
  ))
}


# ==============================================================================
# DEBUGGING AND DIAGNOSTIC FUNCTIONS
# ==============================================================================

#' Diagnose GSEA Results
#'
#' Provides detailed diagnostic information about GSEA results and potential issues.
#'
#' @param gsea_result gseaResult object from run_gsea_analysis()
#' @param verbose Whether to show detailed output (default: TRUE)
#'
#' @return List with diagnostic information
#'
#' @examples
#' diagnostics <- diagnose_gsea_results(gsea_results)
#'
#' @export
diagnose_gsea_results <- function(gsea_result, verbose = TRUE) {
  if (verbose) cat("=== GSEA RESULTS DIAGNOSTICS ===\n")

  # Basic information
  total_pathways <- nrow(gsea_result@result)
  gene_list_length <- length(gsea_result@geneList)

  if (verbose) {
    cat("Total pathways tested:", total_pathways, "\n")
    cat("Gene list length:", gene_list_length, "\n")
  }

  # Check for results
  if (total_pathways == 0) {
    if (verbose) cat("WARNING: No pathways found in results\n")
    return(list(status = "no_results", pathways = 0, genes = gene_list_length))
  }

  # Analyze results
  results_df <- gsea_result@result

  # Check for NA values
  na_enrichment <- sum(is.na(results_df$enrichmentScore))
  na_nes <- sum(is.na(results_df$NES))
  na_pvalue <- sum(is.na(results_df$pvalue))
  na_qvalue <- sum(is.na(results_df$qvalue))

  if (verbose) {
    cat("NA values in results:\n")
    cat("  - Enrichment Score:", na_enrichment, "\n")
    cat("  - NES:", na_nes, "\n")
    cat("  - P-value:", na_pvalue, "\n")
    cat("  - Q-value:", na_qvalue, "\n")
  }

  # Check significance
  sig_05 <- sum(results_df$qvalue < 0.05, na.rm = TRUE)
  sig_01 <- sum(results_df$qvalue < 0.01, na.rm = TRUE)

  if (verbose) {
    cat("Significant pathways:\n")
    cat("  - q < 0.05:", sig_05, "\n")
    cat("  - q < 0.01:", sig_01, "\n")
  }

  # Check gene list properties
  gene_list <- gsea_result@geneList
  gene_range <- range(gene_list, na.rm = TRUE)

  if (verbose) {
    cat("Gene list statistics:\n")
    cat("  - Range:", round(gene_range, 3), "\n")
    cat("  - Mean:", round(mean(gene_list, na.rm = TRUE), 3), "\n")
    cat("  - Median:", round(median(gene_list, na.rm = TRUE), 3), "\n")
  }

  # Check for problematic pathways
  problematic_pathways <- results_df[is.na(results_df$enrichmentScore) |
    is.na(results_df$NES) |
    is.na(results_df$pvalue), ]

  if (nrow(problematic_pathways) > 0 && verbose) {
    cat("Problematic pathways (with NA values):\n")
    for (i in 1:min(5, nrow(problematic_pathways))) {
      cat("  -", problematic_pathways$ID[i], ":", problematic_pathways$Description[i], "\n")
    }
    if (nrow(problematic_pathways) > 5) {
      cat("  ... and", nrow(problematic_pathways) - 5, "more\n")
    }
  }

  # Check for plotting issues
  plottable_pathways <- results_df[!is.na(results_df$enrichmentScore) &
    !is.na(results_df$NES) &
    !is.na(results_df$qvalue) &
    results_df$qvalue < 0.05, ]

  if (verbose) {
    cat("Plottable significant pathways:", nrow(plottable_pathways), "\n")
  }

  # Summary
  status <- "ok"
  if (total_pathways == 0) {
    status <- "no_results"
  } else if (sig_05 == 0) {
    status <- "no_significant"
  } else if (nrow(plottable_pathways) == 0) {
    status <- "no_plottable"
  }

  if (verbose) {
    cat("Status:", status, "\n")
    cat("================================\n")
  }

  return(list(
    status = status,
    total_pathways = total_pathways,
    significant_pathways = sig_05,
    plottable_pathways = nrow(plottable_pathways),
    problematic_pathways = nrow(problematic_pathways),
    gene_list_length = gene_list_length,
    gene_range = gene_range,
    na_counts = list(
      enrichment = na_enrichment,
      nes = na_nes,
      pvalue = na_pvalue,
      qvalue = na_qvalue
    )
  ))
}


#' Create Simple GSEA Plot
#'
#' Creates a simple GSEA plot as a fallback when gseaplot2 fails.
#'
#' @param gsea_result gseaResult object
#' @param pathway_id Pathway ID to plot
#' @param title Plot title
#'
#' @return ggplot object
#'
#' @export
create_simple_gsea_plot <- function(gsea_result, pathway_id, title = NULL) {
  # Get pathway information
  pathway_info <- gsea_result@result[gsea_result@result$ID == pathway_id, ]

  if (nrow(pathway_info) == 0) {
    stop(paste("Pathway", pathway_id, "not found in results"))
  }

  # Create a simple informational plot
  plot_text <- paste0(
    "Pathway: ", pathway_info$Description, "\n",
    "Enrichment Score: ", round(pathway_info$enrichmentScore, 3), "\n",
    "NES: ", round(pathway_info$NES, 3), "\n",
    "P-value: ", scientific(pathway_info$pvalue, digits = 3), "\n",
    "Q-value: ", scientific(pathway_info$qvalue, digits = 3), "\n",
    "Gene Count: ", pathway_info$setSize
  )

  p <- ggplot() +
    annotate("text",
      x = 0.5, y = 0.5,
      label = plot_text,
      size = 4, hjust = 0.5, vjust = 0.5
    ) +
    theme_void() +
    labs(title = title %||% pathway_id) +
    theme(
      plot.title = element_text(size = 14, face = "bold", hjust = 0.5),
      plot.margin = margin(20, 20, 20, 20)
    )

  return(p)
}


#' Create Single GSEA Plot with Multiple Methods
#'
#' Attempts to create a single GSEA plot using multiple methods as fallbacks.
#'
#' @param gsea_result gseaResult object
#' @param pathway_id Pathway ID to plot
#' @param title Plot title (optional)
#' @param methods Vector of methods to try (default: c("gseaplot2", "gseaplot", "simple"))
#' @param verbose Whether to show detailed messages (default: TRUE)
#'
#' @return ggplot object or NULL if all methods fail
#'
#' @examples
#' plot <- create_single_gsea_plot(gsea_results, "mmu04146")
#'
#' @export
create_single_gsea_plot <- function(gsea_result,
                                    pathway_id,
                                    title = NULL,
                                    methods = c("gseaplot2", "gseaplot", "simple"),
                                    verbose = TRUE) {
  # Get pathway information
  pathway_info <- gsea_result@result[gsea_result@result$ID == pathway_id, ]

  if (nrow(pathway_info) == 0) {
    stop(paste("Pathway", pathway_id, "not found in results"))
  }

  if (is.null(title)) {
    title <- paste0(pathway_id, ": ", pathway_info$Description)
  }

  # Try each method
  for (method in methods) {
    if (verbose) cat("Trying method:", method, "\n")

    if (method == "gseaplot2") {
      plot <- tryCatch(
        {
          gseaplot2(gsea_result,
            geneSetID = pathway_id,
            title = title,
            pvalue_table = FALSE,
            base_size = 12
          )
        },
        error = function(e) {
          if (verbose) cat("gseaplot2 failed:", e$message, "\n")
          return(NULL)
        }
      )

      if (!is.null(plot)) {
        if (verbose) cat("Success with gseaplot2!\n")
        return(plot)
      }
    }

    if (method == "gseaplot") {
      plot <- tryCatch(
        {
          gseaplot(gsea_result,
            geneSetID = pathway_id,
            title = title,
            by = "runningScore"
          )
        },
        error = function(e) {
          if (verbose) cat("gseaplot failed:", e$message, "\n")
          return(NULL)
        }
      )

      if (!is.null(plot)) {
        if (verbose) cat("Success with gseaplot!\n")
        return(plot)
      }
    }

    if (method == "simple") {
      plot <- tryCatch(
        {
          create_simple_gsea_plot(gsea_result, pathway_id, title)
        },
        error = function(e) {
          if (verbose) cat("simple plot failed:", e$message, "\n")
          return(NULL)
        }
      )

      if (!is.null(plot)) {
        if (verbose) cat("Success with simple plot!\n")
        return(plot)
      }
    }
  }

  if (verbose) cat("All methods failed for pathway:", pathway_id, "\n")
  return(NULL)
}


# ==============================================================================
# BACKWARD COMPATIBILITY FUNCTIONS
# ==============================================================================

#' Legacy GSEA Function
#'
#' Maintains compatibility with existing runGSEA function.
#'
#' @param gene.dat Gene data with FC and p columns
#' @param term2gene PathID to UniprotID mapping
#' @param term2name PathID to pathway name mapping
#' @param p P-value column name
#' @param p.threshold P-value threshold
#'
#' @return gseaResult object
#'
#' @export
runGSEA <- function(gene.dat, term2gene, term2name, p = "p", p.threshold = 0.05) {
  return(run_gsea_analysis(
    gene_data = gene.dat,
    term2gene = term2gene,
    term2name = term2name,
    p_column = p,
    p_threshold = p.threshold
  ))
}

#' Legacy GSEA Plot Function
#'
#' Maintains compatibility with existing gseaPlot function.
#'
#' @param gsea GSEA result object
#' @param output.dir Output directory
#' @param gsea.q.threshold Q-value threshold
#'
#' @export
gseaPlot <- function(gsea, output.dir, gsea.q.threshold = 0.05) {
  # Create ridge plot
  tryCatch(
    {
      ridge_plot <- create_ridge_plot(gsea)
      if (!is.null(ridge_plot)) {
        ggsave(file.path(output.dir, "ridge_plot.pdf"),
          ridge_plot,
          width = 8, height = 8
        )
        cat("Ridge plot saved successfully\n")
      }
    },
    error = function(e) {
      cat("Ridge plot error:", e$message, "\n")
    }
  )

  # Create individual plots
  pathway_plots_dir <- file.path(output.dir, "gseaplot")
  plots <- create_gsea_plots(
    gsea_result = gsea,
    output_dir = pathway_plots_dir,
    q_threshold = gsea.q.threshold,
    plot_formats = c("pdf", "png"),
    show_progress = TRUE
  )

  cat("Individual pathway plots completed. Generated", length(plots), "plots.\n")
  return(plots)
}

# ==============================================================================
# TROUBLESHOOTING GUIDE
# ==============================================================================
# If you encounter plotting issues, try these debugging steps:
#
# 1. Check your GSEA results:
#    diagnostics <- diagnose_gsea_results(gsea_results)
#    print(diagnostics)
#
# 2. Test a single pathway plot:
#    plot <- create_single_gsea_plot(gsea_results, "mmu04146", verbose = TRUE)
#    print(plot)
#
# 3. Check for data issues:
#    # Look for NA values in enrichment scores
#    na_pathways <- gsea_results@result[is.na(gsea_results@result$enrichmentScore), ]
#    print(na_pathways$ID)
#
# 4. Try different plot methods:
#    plot <- create_single_gsea_plot(gsea_results, "mmu04146",
#                                   methods = c("gseaplot", "simple"))
#
# 5. Use the legacy function with improved error handling:
#    plots <- gseaPlot(gsea_results, output_dir, gsea.q.threshold = 0.05)
#
# Common issues and solutions:
# - "二进列运算符中有非数值参数": Data type issues in pathway data
# - "Generated 0 plots": All pathways failed plotting due to data issues
# - Package version conflicts: Try updating clusterProfiler and enrichplot
# ==============================================================================