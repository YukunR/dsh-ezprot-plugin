# ==============================================================================
# PROTEOMICS ENRICHMENT ANALYSIS FUNCTIONS
# ==============================================================================
# Unified functions for GO and KEGG enrichment analysis with enhanced visualization
#
# Features:
# - Unified interface for GO and KEGG analysis
# - Automatic text wrapping for long descriptions
# - Professional publication-ready plots
# - Flexible parameter control
# - Comprehensive result export
# - Modern ggplot2 styling
#
# Data Structure Expected:
# - gene_list: Data frame with "Gene" column (or specify gene_column)
# - go_background: Columns: GO, UNIPROT, GONAME, ONTOLOGY
# - kegg_background: Columns: PATH, UNIPROT, PATHNAME
#
# Usage Examples:
# 1. GO Analysis:
#    go_results <- run_enrichment_analysis(gene_list, go_background, analysis_type = "GO")
#
# 2. KEGG Analysis:
#    kegg_results <- run_enrichment_analysis(gene_list, kegg_background, analysis_type = "KEGG")
#
# 3. Combined Analysis:
#    results <- run_combined_analysis(gene_list, go_background, kegg_background)
#
# ==============================================================================

library(clusterProfiler)
library(ggplot2)
library(enrichplot)
library(scales)
library(stringr)
library(dplyr)
library(RColorBrewer)

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

#' Wrap Long Text for Better Visualization
#'
#' Automatically wraps long text descriptions to prevent plot distortion.
#' Uses intelligent line breaking at word boundaries.
#'
#' @param text Character vector of text to wrap
#' @param width Maximum characters per line (default: 50)
#' @param max_lines Maximum number of lines (default: 3)
#'
#' @return Character vector with wrapped text
#'
#' @examples
#' wrap_text("This is a very long description that needs wrapping", width = 20)
#'
#' @export
wrap_text <- function(text, width = 50, max_lines = 3) {
  wrapped_text <- sapply(text, function(x) {
    if (nchar(x) <= width) {
      return(x)
    }

    # Split by words
    words <- strsplit(x, " ")[[1]]
    lines <- c()
    current_line <- ""

    for (word in words) {
      # Check if adding this word would exceed width
      if (nchar(paste(current_line, word)) > width && current_line != "") {
        lines <- c(lines, current_line)
        current_line <- word

        # Check if we've reached max lines
        if (length(lines) >= max_lines) {
          # Add ellipsis to the last line if needed
          if (length(words) > length(strsplit(paste(lines, collapse = " "), " ")[[1]])) {
            lines[length(lines)] <- paste0(substr(lines[length(lines)], 1, width - 3), "...")
          }
          break
        }
      } else {
        current_line <- ifelse(current_line == "", word, paste(current_line, word))
      }
    }

    # Add the last line if not empty and within max_lines
    if (current_line != "" && length(lines) < max_lines) {
      lines <- c(lines, current_line)
    }

    return(paste(lines, collapse = "\n"))
  })

  return(unname(wrapped_text))
}


#' Validate Gene List Input
#'
#' Validates and standardizes gene list input for enrichment analysis.
#'
#' @param gene_list Data frame or vector containing gene identifiers
#' @param gene_column Name of the gene column (default: "Gene")
#'
#' @return Standardized gene list data frame
#'
#' @export
validate_gene_list <- function(gene_list, gene_column = "Gene") {
  # Convert vector to data frame if needed
  if (is.vector(gene_list)) {
    gene_list <- data.frame(Gene = gene_list)
    gene_column <- "Gene"
  }

  # Check if gene_column exists
  if (!gene_column %in% colnames(gene_list)) {
    stop(paste(
      "Column", gene_column, "not found in gene_list. Available columns:",
      paste(colnames(gene_list), collapse = ", ")
    ))
  }

  gene_list <- gene_list %>%
    filter(!is.na(.data[[gene_column]]) & .data[[gene_column]] != "") %>%
    distinct(.data[[gene_column]])

  if (nrow(gene_list) == 0) {
    stop("No valid genes found in gene_list after filtering")
  }

  return(gene_list)
}


# ==============================================================================
# ENRICHMENT ANALYSIS FUNCTIONS
# ==============================================================================

#' Run GO Enrichment Analysis
#'
#' Performs Gene Ontology enrichment analysis for all three categories (BP, CC, MF).
#' Returns a comprehensive results data frame.
#'
#' @param gene_list Data frame containing gene identifiers
#' @param go_background GO background data frame with columns: GO, UNIPROT, GONAME, ONTOLOGY
#' @param gene_column Name of the gene column (default: "Gene")
#' @param p_threshold P-value threshold for enrichment (default: 0.05)
#' @param q_threshold Q-value threshold for enrichment (default: 0.2)
#' @param min_gene_size Minimum gene set size (default: 3)
#' @param max_gene_size Maximum gene set size (default: 500)
#'
#' @return Data frame with GO enrichment results
#'
#' @examples
#' go_results <- run_go_analysis(gene_list, go_background)
#'
#' @export
run_go_analysis <- function(gene_list,
                            go_background,
                            gene_column = "Gene",
                            p_threshold = 0.05,
                            q_threshold = 0.2,
                            min_gene_size = 3,
                            max_gene_size = 500) {
  # Validate input
  gene_list <- validate_gene_list(gene_list, gene_column)

  # Check background data
  required_cols <- c("GO", "UNIPROT", "GONAME", "ONTOLOGY")
  missing_cols <- setdiff(required_cols, colnames(go_background))
  if (length(missing_cols) > 0) {
    stop(paste("Missing required columns in go_background:", paste(missing_cols, collapse = ", ")))
  }

  # Prepare term2gene and term2name for each GO category
  prepare_go_terms <- function(ontology) {
    subset_data <- go_background[go_background$ONTOLOGY == ontology, ]
    term2gene <- subset_data[, c("GO", "UNIPROT")]
    term2name <- subset_data[, c("GO", "GONAME")]
    return(list(term2gene = term2gene, term2name = term2name))
  }

  # Get gene vector
  genes <- gene_list[[gene_column]]

  # Perform enrichment for each category
  categories <- c("BP", "CC", "MF")
  category_names <- c("Biological Process", "Cellular Component", "Molecular Function")

  results_list <- list()

  for (i in seq_along(categories)) {
    cat("Processing", category_names[i], "enrichment...\n")

    go_terms <- prepare_go_terms(categories[i])

    tryCatch(
      {
        enrich_result <- enricher(
          gene = genes,
          TERM2GENE = go_terms$term2gene,
          TERM2NAME = go_terms$term2name,
          pAdjustMethod = "BH",
          pvalueCutoff = p_threshold,
          qvalueCutoff = q_threshold,
          minGSSize = min_gene_size,
          maxGSSize = max_gene_size
        )

        if (!is.null(enrich_result) && nrow(enrich_result@result) > 0) {
          result_df <- as.data.frame(enrich_result)
          result_df$Category <- categories[i]
          result_df$Category_Name <- category_names[i]
          results_list[[categories[i]]] <- result_df
        }
      },
      error = function(e) {
        warning(paste("Error in", category_names[i], "enrichment:", e$message))
      }
    )
  }

  # Combine results
  if (length(results_list) == 0) {
    warning("No significant enrichment found for any GO category")
    return(data.frame())
  }

  combined_results <- do.call(rbind, results_list)

  # Add additional columns for plotting
  combined_results$GeneRatio_Numeric <- sapply(combined_results$GeneRatio, function(x) {
    parts <- strsplit(x, "/")[[1]]
    as.numeric(parts[1]) / as.numeric(parts[2])
  })

  combined_results$BgRatio_Numeric <- sapply(combined_results$BgRatio, function(x) {
    parts <- strsplit(x, "/")[[1]]
    as.numeric(parts[1]) / as.numeric(parts[2])
  })

  # Sort by category and p-value
  combined_results <- combined_results[order(combined_results$Category, combined_results$pvalue), ]

  return(combined_results)
}


#' Run KEGG Enrichment Analysis
#'
#' Performs KEGG pathway enrichment analysis.
#'
#' @param gene_list Data frame containing gene identifiers
#' @param kegg_background KEGG background data frame with columns: PATH, UNIPROT, PATHNAME
#' @param gene_column Name of the gene column (default: "Gene")
#' @param p_threshold P-value threshold for enrichment (default: 0.05)
#' @param q_threshold Q-value threshold for enrichment (default: 0.2)
#' @param min_gene_size Minimum gene set size (default: 3)
#' @param max_gene_size Maximum gene set size (default: 500)
#'
#' @return Data frame with KEGG enrichment results
#'
#' @examples
#' kegg_results <- run_kegg_analysis(gene_list, kegg_background)
#'
#' @export
run_kegg_analysis <- function(gene_list,
                              kegg_background,
                              gene_column = "Gene",
                              p_threshold = 0.05,
                              q_threshold = 0.2,
                              min_gene_size = 3,
                              max_gene_size = 500) {
  # Validate input
  gene_list <- validate_gene_list(gene_list, gene_column)

  # Check background data
  required_cols <- c("PATH", "UNIPROT", "PATHNAME")
  missing_cols <- setdiff(required_cols, colnames(kegg_background))
  if (length(missing_cols) > 0) {
    stop(paste("Missing required columns in kegg_background:", paste(missing_cols, collapse = ", ")))
  }

  # Prepare term2gene and term2name
  term2gene <- kegg_background[, c("PATH", "UNIPROT")]
  term2name <- kegg_background[, c("PATH", "PATHNAME")]

  # Get gene vector
  genes <- gene_list[[gene_column]]

  # Perform enrichment
  cat("Processing KEGG pathway enrichment...\n")

  tryCatch(
    {
      kegg_result <- enricher(
        gene = genes,
        TERM2GENE = term2gene,
        TERM2NAME = term2name,
        pAdjustMethod = "BH",
        pvalueCutoff = p_threshold,
        qvalueCutoff = q_threshold,
        minGSSize = min_gene_size,
        maxGSSize = max_gene_size
      )

      if (!is.null(kegg_result) && nrow(kegg_result@result) > 0) {
        result_df <- as.data.frame(kegg_result)
        result_df$Category <- "KEGG"
        result_df$Category_Name <- "KEGG Pathway"

        # Add additional columns for plotting
        result_df$GeneRatio_Numeric <- sapply(result_df$GeneRatio, function(x) {
          parts <- strsplit(x, "/")[[1]]
          as.numeric(parts[1]) / as.numeric(parts[2])
        })

        result_df$BgRatio_Numeric <- sapply(result_df$BgRatio, function(x) {
          parts <- strsplit(x, "/")[[1]]
          as.numeric(parts[1]) / as.numeric(parts[2])
        })

        # Sort by p-value
        result_df <- result_df[order(result_df$pvalue), ]

        return(result_df)
      } else {
        warning("No significant KEGG pathways found")
        return(data.frame())
      }
    },
    error = function(e) {
      warning(paste("Error in KEGG enrichment:", e$message))
      return(data.frame())
    }
  )
}


#' Run Unified Enrichment Analysis
#'
#' Unified interface for running GO or KEGG enrichment analysis.
#'
#' @param gene_list Data frame containing gene identifiers
#' @param background_data Background data frame for GO or KEGG
#' @param analysis_type Type of analysis: "GO" or "KEGG"
#' @param gene_column Name of the gene column (default: "Gene")
#' @param p_threshold P-value threshold (default: 0.05)
#' @param q_threshold Q-value threshold (default: 0.2)
#' @param min_gene_size Minimum gene set size (default: 3)
#' @param max_gene_size Maximum gene set size (default: 500)
#'
#' @return Data frame with enrichment results
#'
#' @examples
#' # GO analysis
#' go_results <- run_enrichment_analysis(gene_list, go_background, "GO")
#'
#' # KEGG analysis
#' kegg_results <- run_enrichment_analysis(gene_list, kegg_background, "KEGG")
#'
#' @export
run_enrichment_analysis <- function(gene_list,
                                    background_data,
                                    analysis_type = c("GO", "KEGG"),
                                    gene_column = "Gene",
                                    p_threshold = 0.05,
                                    q_threshold = 0.2,
                                    min_gene_size = 3,
                                    max_gene_size = 500) {
  analysis_type <- match.arg(analysis_type)

  if (analysis_type == "GO") {
    return(run_go_analysis(
      gene_list, background_data, gene_column,
      p_threshold, q_threshold, min_gene_size, max_gene_size
    ))
  } else if (analysis_type == "KEGG") {
    return(run_kegg_analysis(
      gene_list, background_data, gene_column,
      p_threshold, q_threshold, min_gene_size, max_gene_size
    ))
  }
}


# ==============================================================================
# VISUALIZATION FUNCTIONS
# ==============================================================================

#' Create Enhanced GO Bar Plot
#'
#' Creates a publication-ready GO enrichment bar plot with automatic text wrapping
#' and dual-axis visualization showing both gene ratio and significance.
#'
#' @param go_results GO enrichment results from run_go_analysis()
#' @param display_counts Named vector with display counts for each category (default: c(BP = 10, CC = 5, MF = 5))
#' @param text_width Maximum characters per line for text wrapping (default: 50)
#' @param colors Custom colors for GO categories (optional)
#' @param title Plot title (default: "GO Enrichment Analysis")
#' @param font_size Base font size (default: 12)
#'
#' @return ggplot object
#'
#' @examples
#' go_plot <- create_go_barplot(go_results, display_counts = c(BP = 15, CC = 8, MF = 8))
#'
#' @export
create_go_barplot <- function(go_results,
                              display_counts = c(BP = 10, CC = 5, MF = 5),
                              text_width = 50,
                              colors = NULL,
                              title = "GO Enrichment Analysis",
                              font_size = 12) {
  if (nrow(go_results) == 0) {
    stop("No enrichment results to plot")
  }

  # Set default colors
  if (is.null(colors)) {
    colors <- c(
      "BP" = "#E74C3C",
      "CC" = "#3498DB",
      "MF" = "#2ECC71",
      "GeneRatio" = "#F39C12"
    )
  }

  # Select top results for each category
  plot_data <- data.frame()

  for (category in names(display_counts)) {
    if (category %in% go_results$Category) {
      cat_data <- go_results[go_results$Category == category, ]
      cat_data <- head(cat_data, display_counts[category])
      plot_data <- rbind(plot_data, cat_data)
    }
  }

  if (nrow(plot_data) == 0) {
    stop("No data available for the specified categories")
  }

  # Wrap text descriptions
  plot_data$Description_Wrapped <- wrap_text(plot_data$Description, text_width)

  # Create factor for proper ordering
  plot_data$Description_Wrapped <- factor(
    plot_data$Description_Wrapped,
    levels = rev(plot_data$Description_Wrapped)
  )

  # Calculate scaling for dual axis
  max_gene_ratio <- max(plot_data$GeneRatio_Numeric)
  min_log_p <- min(log10(plot_data$p.adjust))
  max_log_p <- max(log10(plot_data$p.adjust))

  # Scaling function
  scale_factor <- max_gene_ratio / abs(min_log_p)

  # Create the plot
  p <- ggplot(plot_data, aes(y = Description_Wrapped)) +

    # Gene ratio bars (background)
    geom_col(aes(x = GeneRatio_Numeric),
      fill = colors["GeneRatio"],
      alpha = 0.3,
      width = 0.8
    ) +

    # Significance bars (foreground)
    geom_col(
      aes(
        x = log10(p.adjust) * scale_factor,
        fill = Category,
        alpha = -log10(p.adjust)
      ),
      width = 0.8
    ) +

    # Scales
    scale_fill_manual(
      values = colors,
      name = "GO Category",
      labels = c(
        "BP" = "Biological Process",
        "CC" = "Cellular Component",
        "MF" = "Molecular Function"
      )
    ) +
    scale_alpha_continuous(range = c(0.4, 1), guide = "none") +
    scale_x_continuous(
      name = "Gene Ratio",
      limits = c(min_log_p * scale_factor * 1.1, max_gene_ratio * 1.1),
      sec.axis = sec_axis(
        trans = ~ . / scale_factor,
        name = expression(-log[10] ~ "(P.adjust)"),
        breaks = pretty_breaks(n = 5),
        labels = function(x) sprintf("%.1f", -x)
      )
    ) +

    # Annotations
    annotate("text",
      x = min_log_p * scale_factor * 0.8,
      y = 0.8,
      label = expression(-log[10] ~ "(P.adjust)"),
      size = font_size * 0.3,
      color = "gray40"
    ) +
    annotate("text",
      x = max_gene_ratio * 0.8,
      y = 0.8,
      label = "Gene Ratio",
      size = font_size * 0.3,
      color = "gray40"
    ) +

    # Theme and styling
    labs(
      title = title,
      y = NULL
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = font_size * 1.2, face = "bold", hjust = 0.5),
      axis.title = element_text(size = font_size, face = "bold"),
      axis.text = element_text(size = font_size * 0.9),
      axis.text.y = element_text(hjust = 0),
      legend.title = element_text(size = font_size, face = "bold"),
      legend.text = element_text(size = font_size * 0.9),
      legend.position = "bottom",
      panel.grid.major.y = element_blank(),
      panel.grid.minor = element_blank(),
      plot.margin = margin(t = 20, r = 20, b = 20, l = 20)
    )

  return(p)
}


#' Create Enhanced KEGG Plot
#'
#' Creates publication-ready KEGG enrichment plots (dot plot and bar plot).
#'
#' @param kegg_results KEGG enrichment results from run_kegg_analysis()
#' @param display_number Number of pathways to display (default: 15)
#' @param plot_type Type of plot: "dot", "bar", or "both" (default: "both")
#' @param text_width Maximum characters per line for text wrapping (default: 60)
#' @param colors Custom color palette (optional)
#' @param title Plot title (default: "KEGG Pathway Enrichment")
#' @param font_size Base font size (default: 12)
#'
#' @return ggplot object or list of ggplot objects
#'
#' @examples
#' kegg_plots <- create_kegg_plot(kegg_results, display_number = 20, plot_type = "both")
#'
#' @export
create_kegg_plot <- function(kegg_results,
                             display_number = 15,
                             plot_type = c("both", "dot", "bar"),
                             text_width = 60,
                             colors = NULL,
                             title = "KEGG Pathway Enrichment",
                             font_size = 12) {
  plot_type <- match.arg(plot_type)

  if (nrow(kegg_results) == 0) {
    stop("No KEGG enrichment results to plot")
  }

  # Select top results
  plot_data <- head(kegg_results, display_number)

  # Wrap text descriptions
  plot_data$Description_Wrapped <- wrap_text(plot_data$Description, text_width)

  # Create factor for proper ordering
  plot_data$Description_Wrapped <- factor(
    plot_data$Description_Wrapped,
    levels = rev(plot_data$Description_Wrapped)
  )

  # Set color palette
  if (is.null(colors)) {
    colors <- c("#3498DB", "#E74C3C") # Blue to red
  }

  # Create bar plot
  if (plot_type %in% c("bar", "both")) {
    bar_plot <- ggplot(plot_data, aes(y = Description_Wrapped)) +
      geom_col(aes(x = GeneRatio_Numeric, fill = p.adjust),
        alpha = 0.8, width = 0.7
      ) +
      scale_fill_gradient(
        low = colors[2], high = colors[1],
        name = "P.adjust",
        trans = "log10",
        labels = scientific_format()
      ) +
      scale_x_continuous(
        name = "Gene Ratio",
        labels = percent_format(),
        breaks = pretty_breaks(n = 5)
      ) +
      labs(
        title = paste(title, "- Bar Plot"),
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
        legend.position = "right",
        panel.grid.major.y = element_blank(),
        panel.grid.minor = element_blank(),
        plot.margin = margin(t = 20, r = 20, b = 20, l = 20)
      )
  }

  # Arrange by gene ratio
  plot_data <- plot_data %>% arrange(GeneRatio_Numeric)

  plot_data$Description_Wrapped <- factor(
    plot_data$Description_Wrapped,
    levels = plot_data$Description_Wrapped
  )
  # Create dot plot
  if (plot_type %in% c("dot", "both")) {
    dot_plot <- ggplot(plot_data %>% arrange(GeneRatio), aes(y = Description_Wrapped)) +
      geom_point(aes(
        x = GeneRatio_Numeric,
        size = Count,
        color = p.adjust
      )) +
      scale_color_gradient(
        low = colors[2], high = colors[1],
        name = "P.adjust",
        trans = "log10",
        labels = scientific_format()
      ) +
      scale_size_continuous(
        name = "Gene Count",
        range = c(3, 8),
        breaks = pretty_breaks(n = 4)
      ) +
      scale_x_continuous(
        name = "Gene Ratio",
        labels = percent_format(),
        breaks = pretty_breaks(n = 5)
      ) +
      labs(
        title = paste(title, "- Dot Plot"),
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
        legend.position = "right",
        panel.grid.major.y = element_blank(),
        panel.grid.minor = element_blank(),
        plot.margin = margin(t = 20, r = 20, b = 20, l = 20)
      )
  }



  # Return appropriate plots
  if (plot_type == "dot") {
    return(dot_plot)
  } else if (plot_type == "bar") {
    return(bar_plot)
  } else {
    return(list(dot = dot_plot, bar = bar_plot))
  }
}


# ==============================================================================
# COMPREHENSIVE ANALYSIS WRAPPER
# ==============================================================================

#' Run Combined GO and KEGG Analysis
#'
#' Performs comprehensive enrichment analysis including both GO and KEGG,
#' with automatic plot generation and result export.
#'
#' @param gene_list Data frame containing gene identifiers
#' @param go_background GO background data frame
#' @param kegg_background KEGG background data frame
#' @param gene_column Name of the gene column (default: "Gene")
#' @param p_threshold P-value threshold (default: 0.05)
#' @param output_dir Directory to save results (optional)
#' @param file_prefix Prefix for output files (default: "enrichment")
#' @param create_plots Whether to create plots (default: TRUE)
#' @param plot_format Format for plot export (default: "pdf")
#'
#' @return List with GO and KEGG results and plots
#'
#' @examples
#' results <- run_combined_analysis(gene_list, go_background, kegg_background,
#'   output_dir = "results/", file_prefix = "my_analysis"
#' )
#'
#' @export
run_combined_analysis <- function(gene_list,
                                  go_background,
                                  kegg_background,
                                  gene_column = "Gene",
                                  p_threshold = 0.05,
                                  output_dir = NULL,
                                  file_prefix = "enrichment",
                                  create_plots = TRUE,
                                  plot_format = c("pdf", "png", "tiff")) {
  plot_format <- match.arg(plot_format)

  cat("Starting comprehensive enrichment analysis...\n")

  # Run GO analysis
  cat("Running GO analysis...\n")
  go_results <- run_go_analysis(gene_list, go_background, gene_column, p_threshold)

  # Run KEGG analysis
  cat("Running KEGG analysis...\n")
  kegg_results <- run_kegg_analysis(gene_list, kegg_background, gene_column, p_threshold)

  # Create plots if requested
  plots <- list()
  if (create_plots) {
    cat("Creating plots...\n")

    if (nrow(go_results) > 0) {
      plots$go_barplot <- create_go_barplot(go_results)
    }

    if (nrow(kegg_results) > 0) {
      plots$kegg_plots <- create_kegg_plot(kegg_results, plot_type = "both")
    }
  }

  # Export results if output directory is specified
  if (!is.null(output_dir)) {
    cat("Exporting results...\n")

    # Create output directory
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }

    # Export data
    if (nrow(go_results) > 0) {
      write.csv(go_results,
        file.path(output_dir, paste0(file_prefix, "_go_results.csv")),
        row.names = FALSE
      )
    }

    if (nrow(kegg_results) > 0) {
      write.csv(kegg_results,
        file.path(output_dir, paste0(file_prefix, "_kegg_results.csv")),
        row.names = FALSE
      )
    }

    # Export plots
    if (create_plots && length(plots) > 0) {
      if ("go_barplot" %in% names(plots)) {
        ggsave(file.path(output_dir, paste0(file_prefix, "_go_barplot.", plot_format)),
          plots$go_barplot,
          width = 12, height = 8, dpi = 300
        )
      }

      if ("kegg_plots" %in% names(plots)) {
        ggsave(file.path(output_dir, paste0(file_prefix, "_kegg_dotplot.", plot_format)),
          plots$kegg_plots$dot,
          width = 10, height = 8, dpi = 300
        )
        ggsave(file.path(output_dir, paste0(file_prefix, "_kegg_barplot.", plot_format)),
          plots$kegg_plots$bar,
          width = 10, height = 8, dpi = 300
        )
      }
    }
  }

  # Create summary
  summary <- list(
    go_terms_found = nrow(go_results),
    kegg_pathways_found = nrow(kegg_results),
    input_genes = nrow(gene_list),
    analysis_parameters = list(
      p_threshold = p_threshold,
      gene_column = gene_column
    )
  )

  cat("Analysis completed!\n")
  cat("GO terms found:", summary$go_terms_found, "\n")
  cat("KEGG pathways found:", summary$kegg_pathways_found, "\n")

  return(list(
    go_results = go_results,
    kegg_results = kegg_results,
    plots = plots,
    summary = summary
  ))
}