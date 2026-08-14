library(dplyr)
library(tidyr)
library(reshape2)
library(ggplot2)
library(ggforce)
library(gghalves)
library(ggdist)
library(cowplot)
library(multiUS)
library(RColorBrewer)

#' Separate delimited protein IDs
#'
#' @description
#' Handles separation of protein IDs that contain delimiters (e.g., semicolons)
#' into separate rows
#'
#' @param protein_data Data frame containing protein data
#' @param id_col Column name for protein ID, default "Accession"
#' @param gene_col Column name for gene names, default "GeneName"
#' @param desc_col Column name for protein descriptions, default "Description"
#' @param sep Separator for handling multiple IDs, default ";"
#'
#' @return Data frame with separated rows
#'
#' @keywords internal
separate_delimited_ids <- function(protein_data,
                                   id_col = "Accession",
                                   gene_col = "GeneName",
                                   desc_col = "Description",
                                   sep = ";") {
  # Check if required columns exist
  required_cols <- c(id_col, gene_col, desc_col)
  missing_cols <- setdiff(required_cols, colnames(protein_data))
  if (length(missing_cols) > 0) {
    stop(paste("Missing required columns:", paste(missing_cols, collapse = ", ")))
  }

  # Handle multiple IDs separated by delimiter
  # Check if `id_col` contains the specified delimiter
  contain_delimiter <- any(grepl(sep, protein_data[[id_col]], fixed = TRUE))

  if (contain_delimiter) {
    protein_data_separated <- separate_rows(protein_data,
      all_of(c(id_col, gene_col, desc_col)),
      sep = sep
    )
    protein_data_separated <- as.data.frame(protein_data_separated)
    cat("Separated delimited IDs using separator:", sep, "\n")
  } else {
    # In case the delimiter is incorrectly recognized
    protein_data_separated <- as.data.frame(protein_data)
    cat("No delimiter found, data unchanged.\n")
  }

  return(protein_data_separated)
}

#' Resolve duplicate protein IDs
#'
#' @description
#' Detects and resolves duplicate protein IDs using various strategies
#'
#' @param protein_data Data frame containing protein data
#' @param id_col Column name for protein ID, default "Accession"
#' @param gene_col Column name for gene names, default "GeneName"
#' @param desc_col Column name for protein descriptions, default "Description"
#' @param handle_duplicates How to handle duplicate IDs: "error", "interactive", "first", "last", "aggregate"
#' @param output_dir Output directory path
#'
#' @return Data frame with duplicates resolved
#'
#' @keywords internal
resolve_duplicate_ids <- function(protein_data,
                                  id_col = "Accession",
                                  gene_col = "GeneName",
                                  desc_col = "Description",
                                  handle_duplicates = "error",
                                  output_dir = "./") {
  # Check for duplicate IDs
  protein_ids <- protein_data[[id_col]]
  duplicate_ids <- protein_ids[duplicated(protein_ids) | duplicated(protein_ids, fromLast = TRUE)]
  duplicate_ids <- unique(duplicate_ids)

  if (length(duplicate_ids) == 0) {
    cat("No duplicate IDs found.\n")
    return(protein_data)
  }

  cat("Duplicate protein IDs detected:\n")

  # Show detailed information for duplicate IDs
  for (dup_id in duplicate_ids) {
    dup_rows <- which(protein_data[[id_col]] == dup_id)
    cat(sprintf("\nID: %s (appears %d times)\n", dup_id, length(dup_rows)))

    # Show key information for duplicate rows
    dup_data <- protein_data[dup_rows, c(id_col, gene_col, desc_col)]
    print(dup_data)

    # Check if expression data is identical
    expr_cols <- !colnames(protein_data) %in% c(id_col, gene_col, desc_col)
    expr_data_dup <- protein_data[dup_rows, expr_cols, drop = FALSE]

    if (nrow(expr_data_dup) > 1) {
      identical_expr <- all(apply(expr_data_dup, 2, function(x) length(unique(x)) == 1))
      cat(sprintf("Expression data identical: %s\n", ifelse(identical_expr, "Yes", "No")))
    }
  }

  # Handle duplicates based on strategy
  if (handle_duplicates == "error") {
    stop(paste(
      "Duplicate protein IDs found:", paste(duplicate_ids, collapse = ", "),
      "\nPlease check your data or use other handling strategies (first/last/aggregate/interactive)"
    ))
  } else if (handle_duplicates == "interactive") {
    cat("\nPlease choose how to handle duplicate IDs:\n")
    cat("1. Keep first occurrence\n")
    cat("2. Keep last occurrence\n")
    cat("3. Average expression data (only when annotation is identical)\n")
    cat("4. Stop execution to manually fix original file\n")

    choice <- readline(prompt = "Enter your choice (1-4): ")

    if (choice == "1") {
      handle_duplicates <- "first"
    } else if (choice == "2") {
      handle_duplicates <- "last"
    } else if (choice == "3") {
      handle_duplicates <- "aggregate"
    } else {
      stop("Execution stopped. Please fix duplicate IDs in your original data file.")
    }
  }

  # Execute duplicate handling
  if (handle_duplicates == "first") {
    protein_data <- protein_data[!duplicated(protein_data[[id_col]]), ]
    cat("Kept first occurrence for each duplicate ID\n")
  } else if (handle_duplicates == "last") {
    protein_data <- protein_data[!duplicated(protein_data[[id_col]], fromLast = TRUE), ]
    cat("Kept last occurrence for each duplicate ID\n")
  } else if (handle_duplicates == "aggregate") {
    # Check if aggregation is safe
    can_aggregate <- TRUE
    for (dup_id in duplicate_ids) {
      dup_rows <- which(protein_data[[id_col]] == dup_id)
      dup_annotations <- protein_data[dup_rows, c(gene_col, desc_col)]

      if (!all(apply(dup_annotations, 2, function(x) length(unique(x)) == 1))) {
        cat(sprintf("Warning: ID %s has inconsistent annotation, cannot safely aggregate\n", dup_id))
        can_aggregate <- FALSE
      }
    }

    if (!can_aggregate) {
      stop("Cannot aggregate: duplicate IDs with inconsistent annotations found. Please choose another handling method.")
    }

    # Perform aggregation
    expr_cols <- !colnames(protein_data) %in% c(id_col, gene_col, desc_col)

    # Average expression data
    aggregated_data <- protein_data %>%
      group_by(across(all_of(c(id_col, gene_col, desc_col)))) %>%
      summarise(across(all_of(colnames(protein_data)[expr_cols]), mean, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      as.data.frame()

    protein_data <- aggregated_data
    cat("Averaged expression data for duplicate IDs\n")
  }

  # Save duplicate handling report if duplicates were processed
  if (length(duplicate_ids) > 0) {
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }
    report <- data.frame(
      Processing_Time = Sys.time(),
      Duplicate_Count = length(duplicate_ids),
      Duplicate_IDs = paste(duplicate_ids, collapse = "; "),
      Handling_Method = handle_duplicates,
      stringsAsFactors = FALSE
    )
    write.csv(report,
      file = file.path(output_dir, "duplicate_handling_report.csv"),
      row.names = FALSE
    )
    cat(sprintf("Duplicate handling report saved to: %s\n", file.path(output_dir, "duplicate_handling_report.csv")))
  }

  return(protein_data)
}

#' Separate protein data into annotation and expression matrices
#'
#' @description
#' Separates protein data containing both annotation information and expression values
#' into two separate components for downstream analysis. This is a convenience wrapper
#' that handles both ID separation and duplicate resolution.
#'
#' @param protein_data Data frame containing protein annotation and expression data
#' @param id_col Column name for protein ID, default "Accession"
#' @param gene_col Column name for gene names, default "GeneName"
#' @param desc_col Column name for protein descriptions, default "Description"
#' @param output_dir Output directory path
#' @param sep Separator for handling multiple IDs, default ";"
#' @param handle_duplicates How to handle duplicate IDs: "error", "interactive", "first", "last", "aggregate"
#'
#' @return List containing two elements:
#'   \item{expression_data}{Expression data matrix}
#'   \item{annotation_data}{Protein annotation information}
#'
#' @export
separate_protein_data <- function(protein_data,
                                  id_col = "Accession",
                                  gene_col = "GeneName",
                                  desc_col = "Description",
                                  output_dir = "./",
                                  sep = ";",
                                  handle_duplicates = "error") {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Step 1: Separate delimited IDs
  protein_data_separated <- separate_delimited_ids(
    protein_data, id_col, gene_col, desc_col, sep
  )

  # Step 2: Resolve duplicate IDs
  protein_data_final <- resolve_duplicate_ids(
    protein_data_separated, id_col, gene_col, desc_col,
    handle_duplicates, output_dir
  )

  # Step 3: Set row names and extract components
  rownames(protein_data_final) <- protein_data_final[[id_col]]

  # Separate annotation information
  annotation_data <- protein_data_final[, c(id_col, gene_col, desc_col), drop = FALSE]

  # Separate expression data
  expression_data <- protein_data_final[, !colnames(protein_data_final) %in% c(id_col, gene_col, desc_col), drop = FALSE]

  # Save annotation information
  write.csv(annotation_data,
    file = file.path(output_dir, "protein_annotations.csv"),
    row.names = FALSE
  )

  return(list(
    expression_data = expression_data,
    annotation_data = annotation_data
  ))
}

#' Calculate and visualize missing value percentages
#'
#' @description
#' Calculates the percentage of missing values in each sample and generates visualization plots
#'
#' @param expression_data Expression data matrix
#' @param output_dir Output directory path, default current directory
#' @param plot_width Plot width, default 7
#' @param plot_height Plot height, default 5
#'
#' @return Vector of missing value percentages for each sample
#'
#' @export
calculate_na_percentage <- function(expression_data,
                                    output_dir = "./",
                                    plot_width = 7,
                                    plot_height = 5) {
  # Calculate missing value percentage for each sample
  na_percentage <- colSums(is.na(expression_data)) * 100 / nrow(expression_data)
  names(na_percentage) <- colnames(expression_data)

  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Plot missing value percentage bar chart
  pdf(file.path(output_dir, "na_percentage.pdf"),
    height = plot_height, width = plot_width
  )

  barplot(na_percentage,
    ylim = c(0, min(max(na_percentage) + 20, 100)),
    xlab = "Sample",
    ylab = "NA percentage (%)",
    axisnames = FALSE,
    las = 2,
    main = "Missing Value Percentage by Sample"
  )

  # Add value labels
  text(
    x = barplot(na_percentage, plot = FALSE),
    y = na_percentage,
    labels = round(na_percentage, 2),
    pos = 3
  )

  # Add sample name labels
  text(barplot(na_percentage, plot = FALSE),
    par("usr")[3] - 1,
    labels = names(na_percentage),
    srt = 45,
    adj = c(1.1, 1.1),
    xpd = TRUE,
    cex = 0.8
  )

  dev.off()

  # Output summary information
  cat("Missing value analysis completed:\n")
  cat("Average missing percentage:", round(mean(na_percentage), 2), "%\n")
  cat("Range:", round(min(na_percentage), 2), "% -", round(max(na_percentage), 2), "%\n")

  return(na_percentage)
}

#' Median normalization
#'
#' @description
#' Performs median-based normalization across samples, with options for global or within-group normalization
#'
#' @param expression_data Expression data matrix
#' @param sample_info Sample information data frame containing Sample and Group columns
#' @param normalization_method Normalization method:
#'   \itemize{
#'     \item "global" - Global normalization (default)
#'     \item "within_group" - Within-group normalization
#'   }
#' @param use_common_proteins Logical, whether to use only commonly identified proteins
#'   (present in 100% of samples within normalization scope) for calculating normalization
#'   factors. Default FALSE uses all proteins. When TRUE:
#'   \itemize{
#'     \item "global" - Uses proteins present in all samples
#'     \item "within_group" - Uses proteins present in all samples within each group
#'   }
#'   Note: Normalization factors are applied to ALL proteins regardless of this setting.
#' @param sample_col Sample name column, default "Sample"
#' @param group_col Group column, default "Group"
#'
#' @return Normalized expression data matrix
#'
#' @export
normalize_by_median <- function(expression_data,
                                sample_info = NULL,
                                normalization_method = "global",
                                use_common_proteins = FALSE,
                                sample_col = "Sample",
                                group_col = "Group") {
  if (normalization_method == "global") {
    # Global normalization: calculate normalization factors across all samples
    # Filter to common proteins if requested
    if (use_common_proteins) {
      common_proteins <- rowSums(is.na(expression_data)) == 0
      if (sum(common_proteins) == 0) {
        stop("No proteins found in all samples. Cannot use use_common_proteins = TRUE.")
      }
      medians <- apply(expression_data[common_proteins, , drop = FALSE], 2,
                       function(x) median(x, na.rm = TRUE))
      cat("Using", sum(common_proteins), "common proteins for global normalization.\n")
    } else {
      medians <- apply(expression_data, 2, function(x) median(x, na.rm = TRUE))
    }
    if (any(medians == 0, na.rm = TRUE)) {
      zero_samples <- names(medians)[!is.na(medians) & medians == 0]
      stop(paste(
        "Normalization failed: median is 0 for sample(s):",
        paste(zero_samples, collapse = ", "),
        "\nCheck for all-zero or all-NA columns in expression data."
      ))
    }
    norm_factors <- mean(medians) / medians
    normalized_data <- sweep(expression_data, 2, norm_factors, FUN = "*")

    cat("Global median normalization completed.\n")
  } else if (normalization_method == "within_group") {
    # Within-group normalization: calculate normalization factors within each group
    if (is.null(sample_info)) {
      stop("Sample information is required for within-group normalization.")
    }

    # Check required columns
    required_cols <- c(sample_col, group_col)
    missing_cols <- setdiff(required_cols, colnames(sample_info))
    if (length(missing_cols) > 0) {
      stop(paste("Missing columns in sample_info:", paste(missing_cols, collapse = ", ")))
    }

    normalized_data <- expression_data
    groups <- unique(sample_info[[group_col]])

    for (group in groups) {
      # Find samples in current group
      samples_in_group <- sample_info[[sample_col]][sample_info[[group_col]] == group]
      # Check if samples exist in data
      valid_samples <- intersect(samples_in_group, colnames(expression_data))

      if (length(valid_samples) == 0) {
        warning(paste("No valid samples found for group:", group))
        next
      }

      # Get current group data
      group_data <- expression_data[, valid_samples, drop = FALSE]

      # Filter to common proteins if requested
      if (use_common_proteins) {
        common_proteins <- rowSums(is.na(group_data)) == 0
        if (sum(common_proteins) == 0) {
          warning(paste("No common proteins in group:", group,
                       ". Using all proteins for this group."))
          group_medians <- apply(group_data, 2, function(x) median(x, na.rm = TRUE))
        } else {
          group_medians <- apply(group_data[common_proteins, , drop = FALSE], 2,
                        function(x) median(x, na.rm = TRUE))
          cat("Group", group, ":", sum(common_proteins), "common proteins used.\n")
        }
      } else {
        group_medians <- apply(group_data, 2, function(x) median(x, na.rm = TRUE))
      }

      # Calculate normalization factors
      if (any(group_medians == 0, na.rm = TRUE)) {
        zero_samples <- names(group_medians)[!is.na(group_medians) & group_medians == 0]
        stop(paste(
          "Normalization failed: median is 0 for sample(s) in group", group, ":",
          paste(zero_samples, collapse = ", "),
          "\nCheck for all-zero or all-NA columns in expression data."
        ))
      }
      norm_factors <- mean(group_medians) / group_medians
      # Apply normalization
      normalized_data[, valid_samples] <- sweep(group_data, 2, norm_factors, FUN = "*")
    }

    cat("Within-group median normalization completed.\n")
  } else {
    stop("Invalid normalization_method. Use 'global' or 'within_group'.")
  }

  return(normalized_data)
}

#' Log2 transformation
#'
#' @description
#' Performs log2 transformation on data, handling zero and negative values
#'
#' @param expression_data Expression data matrix
#' @param zero_handling Method for handling zero values:
#'   \itemize{
#'     \item "replace_with_na" - Replace with NA (default)
#'     \item "add_pseudocount" - Add pseudocount
#'   }
#' @param pseudocount Pseudocount value, default 1
#'
#' @return log2-transformed data matrix
#'
#' @export
log2_transform <- function(expression_data,
                           zero_handling = "replace_with_na",
                           pseudocount = 1) {
  if (zero_handling == "replace_with_na") {
    # Replace zero values with NA, then perform log2 transformation
    log2_data <- log2(replace(expression_data, expression_data == 0 | is.na(expression_data), NA))
  } else if (zero_handling == "add_pseudocount") {
    # Add pseudocount then perform log2 transformation
    log2_data <- log2(expression_data + pseudocount)
  } else {
    stop("Invalid zero_handling method. Use 'replace_with_na' or 'add_pseudocount'.")
  }

  cat("Log2 transformation completed.\n")
  cat("Method:", zero_handling, "\n")
  if (zero_handling == "add_pseudocount") {
    cat("Pseudocount:", pseudocount, "\n")
  }

  return(log2_data)
}

#' Create violin and density plots for data visualization
#'
#' @description
#' Generates violin plots (with boxplots and jitter points) and density plots
#' to visualize data distribution across samples, with samples colored by group
#'
#' @param melted_data Long-format data with columns: Sample, Intensity, Group
#' @param group_colors Named vector of colors for each group (can be from generate_sample_colors())
#' @param output_dir Output directory
#' @param file_suffix File suffix for plot names
#' @param plot_width Plot width, default 7
#' @param plot_height Plot height, default 5
#'
#' @return List containing violin and density plot objects
#'
#' @export
create_distribution_plots <- function(melted_data,
                                      group_colors,
                                      output_dir = "./",
                                      file_suffix = "distribution",
                                      plot_width = 7,
                                      plot_height = 5) {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Handle different input formats for group_colors
  if (is.list(group_colors) && "group_colors" %in% names(group_colors)) {
    # If input is result from generate_sample_colors()
    actual_group_colors <- group_colors$group_colors
    sample_colors <- group_colors$sample_colors
  } else {
    # If input is direct named vector
    actual_group_colors <- group_colors
    # Map sample colors based on group
    sample_colors <- actual_group_colors[melted_data$Group]
    names(sample_colors) <- melted_data$Sample
    # Remove duplicates to get unique sample-color mapping
    sample_colors <- sample_colors[!duplicated(names(sample_colors))]
  }

  # Violin plot with boxplot and jitter (by Sample, colored by Group)
  violin_plot <- ggplot(melted_data, aes(x = Sample, y = Intensity, fill = Group)) +
    geom_half_violin(
      position = position_nudge(x = 0.25),
      side = "r",
      width = 0.8,
      color = NA
    ) +
    geom_jitter(aes(fill = Group, colour = Group),
      shape = 21,
      size = 0.5,
      width = 0.2
    ) +
    geom_boxplot(
      width = 0.4,
      size = 1.2,
      outlier.color = NA,
      linewidth = 0.4
    ) +
    scale_fill_manual(values = actual_group_colors) +
    scale_color_manual(values = actual_group_colors) +
    ylab("log2(Intensity)") +
    xlab("Sample") +
    theme_bw() +
    theme(
      panel.grid = element_blank(),
      axis.text = element_text(color = "black", size = 10),
      axis.title = element_text(color = "black", size = 12),
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "right"
    ) +
    scale_y_continuous(expand = c(0, 0))

  # Save violin plot
  ggsave(violin_plot,
    filename = file.path(output_dir, paste0(file_suffix, "_violin.pdf")),
    width = plot_width,
    height = plot_height
  )

  # Density plot (by Sample, colored by Group)
  density_plot <- ggplot(melted_data, aes(x = Intensity, color = Group, group = Sample)) +
    geom_density(
      show.legend = TRUE,
      key_glyph = "timeseries",
      linewidth = 0.7
    ) +
    scale_color_manual(values = actual_group_colors) +
    theme_bw() +
    theme(
      panel.grid = element_blank(),
      axis.text = element_text(color = "black", size = 10),
      axis.title = element_text(color = "black", size = 12),
      legend.position = "right"
    ) +
    xlab("log2(Intensity)") +
    guides(color = guide_legend(title = "Group"))

  # Save density plot
  ggsave(density_plot,
    filename = file.path(output_dir, paste0(file_suffix, "_density.pdf")),
    width = plot_width,
    height = plot_height
  )

  cat("Distribution plots saved:\n")
  cat("Violin:", file.path(output_dir, paste0(file_suffix, "_violin.pdf")), "\n")
  cat("Density:", file.path(output_dir, paste0(file_suffix, "_density.pdf")), "\n")

  return(list(violin = violin_plot, density = density_plot))
}

#' Comprehensive visualization of normalization and imputation effects
#'
#' @description
#' Creates comprehensive visualization comparing raw, normalized, and imputed data
#' using both violin plots and density plots. Shows each sample individually, colored by group.
#'
#' @param raw_data Raw expression data matrix
#' @param normalized_data Normalized expression data matrix
#' @param imputed_data Imputed expression data matrix (log2 scale)
#' @param sample_info Sample information with Sample and Group columns
#' @param custom_colors Named vector of custom colors for groups (optional)
#' @param output_dir Output directory
#' @param sample_col Sample column name, default "Sample"
#' @param group_col Group column name, default "Group"
#' @param palette Color palette if custom_colors not provided, default "Set2"
#' @param plot_width Combined plot width, default 10
#' @param plot_height Combined plot height, default 10
#'
#' @return List containing the combined plot and color scheme for reuse
#'
#' @export
visualize_normalization_workflow <- function(raw_data,
                                             normalized_data,
                                             imputed_data,
                                             sample_info,
                                             custom_colors = NULL,
                                             output_dir = "./",
                                             sample_col = "Sample",
                                             group_col = "Group",
                                             palette = "Set2",
                                             plot_width = 10,
                                             plot_height = 10) {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Prepare raw data (log2 transform, replace 0 with NA)
  raw_log2 <- log2(replace(raw_data, raw_data == 0 | is.na(raw_data), NA))
  raw_log2$Accession <- rownames(raw_log2)
  raw_melted <- melt(raw_log2,
    id.vars = "Accession",
    variable.name = "Sample",
    value.name = "Intensity"
  )

  # Prepare normalized data (log2 transform, replace 0 with NA)
  norm_log2 <- log2(replace(normalized_data, normalized_data == 0 | is.na(normalized_data), NA))
  norm_log2$Accession <- rownames(norm_log2)
  norm_melted <- melt(norm_log2,
    id.vars = "Accession",
    variable.name = "Sample",
    value.name = "Intensity"
  )

  # Prepare imputed data (already in log2 scale)
  imputed_df <- as.data.frame(imputed_data)
  imputed_melted <- melt(imputed_df,
    variable.name = "Sample",
    value.name = "Intensity"
  )

  # Add group information to all datasets
  add_group_info <- function(data) {
    merge(data, sample_info, by.x = "Sample", by.y = sample_col, all.x = TRUE)
  }

  raw_melted <- add_group_info(raw_melted)
  norm_melted <- add_group_info(norm_melted)
  imputed_melted <- add_group_info(imputed_melted)

  # Generate colors for samples based on groups
  color_scheme <- generate_sample_colors(
    sample_info, sample_col, group_col,
    custom_colors, palette
  )

  # Create plots for each stage
  raw_plots <- create_distribution_plots(
    raw_melted, color_scheme,
    output_dir, "raw",
    plot_width / 2, plot_height / 3
  )

  norm_plots <- create_distribution_plots(
    norm_melted, color_scheme,
    output_dir, "normalized",
    plot_width / 2, plot_height / 3
  )

  imputed_plots <- create_distribution_plots(
    imputed_melted, color_scheme,
    output_dir, "imputed",
    plot_width / 2, plot_height / 3
  )

  # Combine all plots into a grid
  combined_plot <- plot_grid(
    raw_plots$violin, raw_plots$density,
    norm_plots$violin, norm_plots$density,
    imputed_plots$violin, imputed_plots$density,
    ncol = 2,
    labels = LETTERS[1:6],
    label_size = 12
  )

  # Save combined plot
  ggsave(combined_plot,
    filename = file.path(output_dir, "normalization_workflow_comparison.pdf"),
    width = plot_width,
    height = plot_height
  )

  ggsave(combined_plot,
    filename = file.path(output_dir, "normalization_workflow_comparison.tiff"),
    width = plot_width,
    height = plot_height,
    dpi = 150
  )

  cat("Comprehensive workflow visualization completed:\n")
  cat("PDF:", file.path(output_dir, "normalization_workflow_comparison.pdf"), "\n")
  cat("TIFF:", file.path(output_dir, "normalization_workflow_comparison.tiff"), "\n")

  # Return both the plot and color scheme for reuse
  return(list(
    combined_plot = combined_plot,
    color_scheme = color_scheme
  ))
}

#' Generate color palette for samples based on groups
#'
#' @description
#' Creates a color palette for sample visualization, where samples from the same group get the same color.
#' Allows custom color specification or automatic generation.
#'
#' @param sample_info Data frame with Sample and Group columns
#' @param sample_col Sample column name, default "Sample"
#' @param group_col Group column name, default "Group"
#' @param custom_colors Named vector of custom colors for groups (optional)
#' @param palette Color palette to use if custom_colors not provided: "Set1", "Set2", "Dark2", "Paired", default "Set2"
#' @param return_scheme Whether to return the color scheme for reuse in other functions, default TRUE
#'
#' @return List containing:
#'   \item{group_colors}{Named vector of group colors}
#'   \item{sample_colors}{Named vector of sample colors}
#'   \item{color_mapping}{Data frame showing group-color mapping for reference}
#'
#' @export
generate_sample_colors <- function(sample_info,
                                   sample_col = "Sample",
                                   group_col = "Group",
                                   custom_colors = NULL,
                                   palette = "Set2",
                                   return_scheme = TRUE) {
  # Get unique groups
  unique_groups <- unique(sample_info[[group_col]])
  n_groups <- length(unique_groups)

  # Generate or use custom group colors
  if (!is.null(custom_colors)) {
    # Use custom colors
    if (is.null(names(custom_colors))) {
      # If no names provided, assign to groups in order
      if (length(custom_colors) < n_groups) {
        stop("Not enough custom colors provided. Need ", n_groups, " colors for ", n_groups, " groups.")
      }
      group_colors <- custom_colors[1:n_groups]
      names(group_colors) <- unique_groups
    } else {
      # Use named custom colors
      missing_groups <- setdiff(unique_groups, names(custom_colors))
      if (length(missing_groups) > 0) {
        stop("Missing colors for groups: ", paste(missing_groups, collapse = ", "))
      }
      group_colors <- custom_colors[unique_groups]
    }
    cat("Using custom color scheme.\n")
  } else {
    # Generate automatic colors
    if (n_groups <= 8) {
      group_colors <- RColorBrewer::brewer.pal(max(3, n_groups), palette)
    } else {
      # For more than 8 groups, use rainbow colors
      group_colors <- rainbow(n_groups)
    }
    names(group_colors) <- unique_groups
    cat("Generated automatic color scheme using palette:", palette, "\n")
  }

  # Map sample colors based on group
  sample_colors <- group_colors[sample_info[[group_col]]]
  names(sample_colors) <- sample_info[[sample_col]]

  # Create color mapping reference
  color_mapping <- data.frame(
    Group = unique_groups,
    Color = group_colors[unique_groups],
    HEX = group_colors[unique_groups],
    stringsAsFactors = FALSE
  )

  # Print color scheme for user reference
  cat("\nColor scheme:\n")
  for (i in 1:nrow(color_mapping)) {
    cat(sprintf("  %s: %s\n", color_mapping$Group[i], color_mapping$Color[i]))
  }
  cat("\n")

  result <- list(
    group_colors = group_colors,
    sample_colors = sample_colors,
    color_mapping = color_mapping
  )

  if (return_scheme) {
    return(result)
  } else {
    return(group_colors)
  }
}

#' Perseus-style missing value imputation
#'
#' @description
#' Imputes missing values using random numbers from a normal distribution with downshifted mean
#' and shrunken standard deviation, similar to Perseus software methodology
#'
#' @param expression_matrix Expression data matrix
#' @param width Scaling factor for imputed distribution standard deviation relative to sample standard deviation, default 0.3
#' @param downshift Downshift of imputed distribution mean from sample mean (in units of sample standard deviation), default 1.8
#' @param seed Random seed, default 100
#'
#' @return Matrix with imputed values
#'
#' @export
impute_perseus_style <- function(expression_matrix,
                                 width = 0.3,
                                 downshift = 1.8,
                                 seed = 100) {
  if (!is.matrix(expression_matrix)) {
    expression_matrix <- as.matrix(expression_matrix)
  }

  # Check if data is log-transformed
  mx <- max(expression_matrix, na.rm = TRUE)
  mn <- min(expression_matrix, na.rm = TRUE)
  if (mx - mn > 20) {
    warning("Please make sure the values are log-transformed")
  }

  set.seed(seed)

  imputed_matrix <- apply(expression_matrix, 2, function(column) {
    # Handle non-finite values
    column[!is.finite(column)] <- NA

    # Skip imputation for all-NA columns to avoid silent NaN fill
    if (all(is.na(column))) {
      warning("A column is entirely NA; Perseus-style imputation skipped for this column.")
      return(column)
    }

    # Calculate statistical parameters
    column_sd <- sd(column, na.rm = TRUE)
    column_mean <- mean(column, na.rm = TRUE)

    # Calculate imputation parameters
    shrinked_sd <- width * column_sd
    downshifted_mean <- column_mean - downshift * column_sd

    # Impute missing values
    n_missing <- sum(is.na(column))
    if (n_missing > 0) {
      column[is.na(column)] <- rnorm(n_missing,
        mean = downshifted_mean,
        sd = shrinked_sd
      )
    }

    return(column)
  })

  cat("Perseus-style imputation completed.\n")
  cat("Parameters: width =", width, ", downshift =", downshift, ", seed =", seed, "\n")

  return(imputed_matrix)
}

#' Data filtering and group-wise imputation
#'
#' @description
#' Filters proteins based on the proportion of non-missing values in each group,
#' then performs group-wise missing value imputation
#'
#' @param log2_data log2-transformed data matrix
#' @param sample_info Sample information containing Sample and Group columns
#' @param filter_threshold Filter threshold (NA threshold): can be a single value or vector of 2 values, default c(0.6, 0.9)
#'   \itemize{
#'     \item Single value: backward compatible behavior
#'     \item Vector of 2 values c(threshold1, threshold2): enables two-threshold system
#'   }
#' @param impute_method Imputation method: "perseus", "knn", or "auto", default "perseus"
#'   \itemize{
#'     \item "perseus" - Perseus-style imputation for all proteins (with filtering at threshold[1])
#'     \item "knn" - KNN imputation for all proteins (with filtering at threshold[1])
#'     \item "auto" - Adaptive imputation with optional two-threshold system:
#'       \itemize{
#'         \item Single threshold: NO filtering, KNN for NA <= threshold, Perseus for NA > threshold
#'         \item Two thresholds c(t1, t2): NA < t1 -> KNN, t1 <= NA < t2 -> Perseus, NA >= t2 -> discard
#'       }
#'   }
#' @param sample_col Sample name column, default "Sample"
#' @param group_col Group column, default "Group"
#' @param output_dir Output directory
#' @param knn_k K value for KNN imputation, default 10
#'
#' @return Filtered and imputed data matrix
#'
#' @export
filter_and_impute <- function(log2_data,
                              sample_info,
                              filter_threshold = c(0.6, 0.9),
                              impute_method = "perseus",
                              sample_col = "Sample",
                              group_col = "Group",
                              output_dir = "./",
                              knn_k = 10) {
  # Check input parameters
  if (!is.data.frame(sample_info)) {
    stop("sample_info must be a data frame")
  }

  required_cols <- c(sample_col, group_col)
  missing_cols <- setdiff(required_cols, colnames(sample_info))
  if (length(missing_cols) > 0) {
    stop(paste("Missing columns in sample_info:", paste(missing_cols, collapse = ", ")))
  }

  # Validate impute_method
  if (!impute_method %in% c("perseus", "knn", "auto")) {
    stop("Invalid impute_method. Use 'perseus', 'knn', or 'auto'.")
  }

  # Validate filter_threshold parameter
  if (!is.numeric(filter_threshold) || length(filter_threshold) == 0) {
    stop("filter_threshold must be a numeric vector with 1 or 2 values")
  }

  if (length(filter_threshold) > 2) {
    warning("filter_threshold has more than 2 values. Only the first 2 will be used.")
    filter_threshold <- filter_threshold[1:2]
  }

  # Parse threshold values
  if (length(filter_threshold) == 1) {
    threshold_low <- filter_threshold[1]
    threshold_high <- filter_threshold[1]
    is_two_threshold_mode <- FALSE

    if (threshold_low < 0 || threshold_low > 1) {
      stop(sprintf(
        "Invalid filter_threshold: value (%.2f) must be between 0 and 1",
        threshold_low
      ))
    }
  } else {
    threshold_low <- filter_threshold[1]
    threshold_high <- filter_threshold[2]
    is_two_threshold_mode <- TRUE

    if (threshold_low > threshold_high) {
      stop(sprintf(
        "Invalid filter_threshold: first value (%.2f) must be <= second value (%.2f)",
        threshold_low, threshold_high
      ))
    }

    if (threshold_low < 0 || threshold_high > 1) {
      stop("filter_threshold values must be between 0 and 1")
    }
  }

  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Prepare data for filtering
  # Replace -Inf with NA (result of log(0))
  log2_data[log2_data == -Inf] <- NA

  # Add Accession column for downstream processing
  log2_data_with_id <- log2_data
  log2_data_with_id$Accession <- rownames(log2_data)

  # Convert data to long format
  log2_data_long <- melt(log2_data_with_id,
    id.vars = "Accession",
    variable.name = "Sample",
    value.name = "Intensity"
  )

  # Calculate total sample count per group
  sample_info_with_count <- sample_info %>%
    add_count(!!sym(group_col), name = "total_count")

  # Merge data
  data_for_filtering <- merge(log2_data_long,
    sample_info_with_count,
    by.x = "Sample",
    by.y = sample_col,
    all.x = TRUE
  )

  # Calculate filtering statistics per protein per group
  protein_group_stats <- data_for_filtering %>%
    group_by(Accession, !!sym(group_col)) %>%
    summarise(
      na_count = sum(is.na(Intensity)),
      total_count = first(total_count),
      na_percentage = na_count / total_count,
      .groups = "drop"
    )

  # Calculate maximum NA percentage across all groups for each protein
  protein_stats <- protein_group_stats %>%
    group_by(Accession) %>%
    summarise(
      max_na_percentage = max(na_percentage),
      .groups = "drop"
    )

  # Filtering step: only apply for perseus and knn methods, NOT for auto
  if (impute_method %in% c("perseus", "knn")) {
    # Filter proteins: keep those with NA percentage <= threshold_low in ALL groups
    filtered_proteins <- protein_stats %>%
      filter(max_na_percentage <= threshold_low)

    cat("Filtering completed:\n")
    cat("Original proteins:", nrow(log2_data), "\n")
    cat("Proteins after filtering:", nrow(filtered_proteins), "\n")
    if (is_two_threshold_mode) {
      cat("NA threshold (using first value):", threshold_low, "\n")
      cat("  (Note: second threshold value", threshold_high,
          "is ignored for", impute_method, "mode)\n")
    } else {
      cat("NA threshold:", threshold_low, "\n")
    }

    # Apply filtering
    filtered_log2_data <- log2_data[filtered_proteins$Accession, , drop = FALSE]
  } else {
    # Auto mode: filtering and adaptive imputation based on threshold(s)
    if (is_two_threshold_mode) {
      cat("Auto mode: Two-threshold adaptive imputation\n")
      cat("Total proteins:", nrow(log2_data), "\n")
      cat(sprintf("  NA ratio < %.2f: KNN imputation\n", threshold_low))
      cat(sprintf("  %.2f <= NA ratio < %.2f: Perseus imputation\n",
                  threshold_low, threshold_high))
      cat(sprintf("  NA ratio >= %.2f: Discard (filter out)\n", threshold_high))

      # Apply filtering: remove proteins with NA ratio >= threshold_high
      filtered_proteins <- protein_stats %>%
        filter(max_na_percentage < threshold_high)

      cat("Proteins after filtering:", nrow(filtered_proteins), "\n")
      filtered_log2_data <- log2_data[filtered_proteins$Accession, , drop = FALSE]
    } else {
      cat("Auto mode: No filtering applied (all proteins retained for adaptive imputation)\n")
      cat("Total proteins:", nrow(log2_data), "\n")
      cat("NA threshold for method selection:", threshold_low, "\n")

      filtered_log2_data <- log2_data
    }
  }

  # Group data by groups for imputation
  groups <- unique(sample_info[[group_col]])
  grouped_data <- list()

  for (group in groups) {
    samples_in_group <- sample_info[[sample_col]][sample_info[[group_col]] == group]
    valid_samples <- intersect(samples_in_group, colnames(filtered_log2_data))

    if (length(valid_samples) > 0) {
      grouped_data[[group]] <- filtered_log2_data[, valid_samples, drop = FALSE]
    }
  }

  # Perform imputation based on method
  if (impute_method == "perseus") {
    imputed_groups <- lapply(grouped_data, impute_perseus_style)
    cat("Imputation completed using method: perseus\n")
  } else if (impute_method == "knn") {
    imputed_groups <- lapply(grouped_data, function(x) {
      res <- multiUS::KNNimp(x, k = knn_k)
      res <- as.data.frame(res)
      colnames(res) <- colnames(x)
      res
    })
    cat("Imputation completed using method: knn\n")
  } else if (impute_method == "auto") {
    # Auto mode: use different methods based on NA ratio per protein per group
    # NA ratio > threshold -> Perseus (more missing, use random imputation)
    # NA ratio <= threshold -> KNN (less missing, use neighbor-based imputation)
    cat("Using auto imputation mode...\n")
    if (is_two_threshold_mode) {
      cat(sprintf("  NA ratio < %.2f -> KNN\n", threshold_low))
      cat(sprintf("  %.2f <= NA ratio < %.2f -> Perseus\n",
                  threshold_low, threshold_high))
      cat(sprintf("  (Proteins with NA ratio >= %.2f were already filtered out)\n",
                  threshold_high))
    } else {
      cat(sprintf("  NA ratio > %.2f -> Perseus\n", threshold_low))
      cat(sprintf("  NA ratio <= %.2f -> KNN\n", threshold_low))
    }

    imputed_groups <- list()

    for (group in names(grouped_data)) {
      group_data <- grouped_data[[group]]
      n_samples <- ncol(group_data)

      # Calculate NA ratio for each protein in this group
      na_ratios <- rowSums(is.na(group_data)) / n_samples

      # Classify proteins based on NA threshold(s)
      if (is_two_threshold_mode) {
        knn_proteins <- names(na_ratios[na_ratios < threshold_low])
        perseus_proteins <- names(na_ratios[na_ratios >= threshold_low &
                                            na_ratios < threshold_high])
      } else {
        knn_proteins <- names(na_ratios[na_ratios <= threshold_low])
        perseus_proteins <- names(na_ratios[na_ratios > threshold_low])
      }

      if (is_two_threshold_mode) {
        cat(sprintf(
          "  Group '%s': %d proteins for KNN (NA < %.2f), %d proteins for Perseus (%.2f <= NA < %.2f)\n",
          group, length(knn_proteins), threshold_low,
          length(perseus_proteins), threshold_low, threshold_high
        ))
      } else {
        cat(sprintf(
          "  Group '%s': %d proteins for KNN (NA <= %.2f), %d proteins for Perseus (NA > %.2f)\n",
          group, length(knn_proteins), threshold_low,
          length(perseus_proteins), threshold_low
        ))
      }

      # Initialize result matrix
      imputed_group_data <- group_data

      # Apply KNN imputation to proteins with less missing data
      if (length(knn_proteins) > 0) {
        knn_data <- group_data[knn_proteins, , drop = FALSE]
        # Only apply KNN if there are missing values
        if (any(is.na(knn_data))) {
          knn_imputed <- multiUS::KNNimp(knn_data, k = min(knn_k, n_samples - 1))
          knn_imputed <- as.data.frame(knn_imputed)
          colnames(knn_imputed) <- colnames(knn_data)
          imputed_group_data[knn_proteins, ] <- knn_imputed
        }
      }

      # Apply Perseus imputation to proteins with more missing data
      if (length(perseus_proteins) > 0) {
        perseus_data <- group_data[perseus_proteins, , drop = FALSE]
        # Only apply Perseus if there are missing values
        if (any(is.na(perseus_data))) {
          perseus_imputed <- impute_perseus_style(as.matrix(perseus_data))
          imputed_group_data[perseus_proteins, ] <- perseus_imputed
        }
      }

      imputed_groups[[group]] <- imputed_group_data
    }

    cat("Imputation completed using method: auto\n")
  }

  # Combine imputed data
  names(imputed_groups) <- NULL
  imputed_data <- do.call(cbind, imputed_groups)
  cat("Imputed result:", if (is.null(imputed_data)) "NULL" else paste(dim(imputed_data), collapse = "x"), "\n")

  # Ensure column order matches original data
  original_order <- intersect(colnames(log2_data), colnames(imputed_data))
  imputed_data <- imputed_data[, original_order, drop = FALSE]

  # Save imputation method report for auto mode
  if (impute_method == "auto") {
    # Create detailed report
    auto_report <- data.frame(
      Accession = character(),
      Group = character(),
      NA_Ratio = numeric(),
      Method_Used = character(),
      stringsAsFactors = FALSE
    )

    for (group in names(grouped_data)) {
      group_data <- grouped_data[[group]]
      n_samples <- ncol(group_data)
      na_ratios <- rowSums(is.na(group_data)) / n_samples

      group_report <- data.frame(
        Accession = names(na_ratios),
        Group = group,
        NA_Ratio = round(na_ratios, 4),
        Method_Used = if (is_two_threshold_mode) {
          ifelse(na_ratios < threshold_low, "KNN",
                 ifelse(na_ratios < threshold_high, "Perseus", "Filtered"))
        } else {
          ifelse(na_ratios > threshold_low, "Perseus", "KNN")
        },
        stringsAsFactors = FALSE
      )
      auto_report <- rbind(auto_report, group_report)
    }

    write.csv(auto_report,
      file.path(output_dir, "auto_imputation_report.csv"),
      row.names = FALSE
    )
    cat(
      "Auto imputation report saved to:",
      file.path(output_dir, "auto_imputation_report.csv"), "\n"
    )
  }

  return(imputed_data)
}

#' Save processed data
#'
#' @description
#' Converts log2 data back to original scale and saves as CSV and TXT formats
#'
#' @param log2_data log2-transformed data matrix
#' @param output_dir Output directory
#' @param file_prefix File name prefix, default "protein_abundance_data"
#' @param add_accession Whether to add Accession column, default TRUE
#'
#' @export
save_processed_data <- function(log2_data,
                                output_dir = "./",
                                file_prefix = "protein_abundance_data",
                                add_accession = TRUE) {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Convert back to original scale
  original_scale_data <- 2^log2_data

  # Convert to data frame
  output_data <- as.data.frame(original_scale_data)

  # Add Accession column
  if (add_accession) {
    output_data$Accession <- rownames(output_data)
    # Move Accession column to first position
    output_data <- output_data[, c("Accession", setdiff(colnames(output_data), "Accession")), drop = FALSE]
  }

  # Save as CSV format
  csv_file <- file.path(output_dir, paste0(file_prefix, ".csv"))
  write.csv(output_data, csv_file, row.names = FALSE)

  # Save as TXT format (tab-delimited)
  txt_file <- file.path(output_dir, paste0(file_prefix, ".txt"))
  write.table(output_data, txt_file,
    row.names = FALSE, sep = "\t", quote = FALSE
  )

  cat("Data saved to:\n")
  cat("CSV:", csv_file, "\n")
  cat("TXT:", txt_file, "\n")
}

#' Row normalization function
#'
#' @description
#' Normalizes each row (protein) to achieve a target sum across samples
#'
#' @param protein_data Data frame containing Accession column and expression data
#' @param target_sum_per_sample Target sum per sample, default 100
#' @param id_col Protein ID column name, default "Accession"
#'
#' @return Row-normalized data frame
#'
#' @export
normalize_by_row <- function(protein_data,
                             target_sum_per_sample = 100,
                             id_col = "Accession") {
  # Check if ID column exists
  if (!id_col %in% colnames(protein_data)) {
    stop(paste("Column", id_col, "not found in data"))
  }

  # Separate ID column and expression data
  id_data <- protein_data[, id_col, drop = FALSE]
  expression_data <- protein_data[, !colnames(protein_data) %in% id_col, drop = FALSE]

  # Calculate target total sum
  total_target_sum <- target_sum_per_sample * ncol(expression_data)

  # Calculate current row sums
  row_sums <- rowSums(expression_data, na.rm = TRUE)

  # Calculate calibration factors
  calibration_factors <- row_sums / total_target_sum

  # Apply normalization
  normalized_expression <- sweep(expression_data, 1, calibration_factors, FUN = "/")

  # Combine results
  normalized_data <- cbind(id_data, normalized_expression)

  cat("Row normalization completed.\n")
  cat("Target sum per sample:", target_sum_per_sample, "\n")

  return(normalized_data)
}