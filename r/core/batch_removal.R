library(sva)
library(ggplot2)
library(tidyverse)

#' Display PCA plot for batch effect assessment
#'
#' @description
#' Shows the PCA biplot to help users assess if batch removal is needed
#'
#' @param pca_plot_path Path to the PCA biplot PDF file
#' @param viewer_available Whether a viewer is available (e.g., RStudio)
#'
#' @return NULL
#'
#' @export
display_pca_for_batch_assessment <- function(pca_plot_path, viewer_available = TRUE) {
  if (!file.exists(pca_plot_path)) {
    stop("PCA plot file not found: ", pca_plot_path)
  }

  cat("\n=== Batch Effect Assessment ===\n")
  cat("Please examine the PCA plot to determine if batch removal is needed.\n")
  cat("Look for clustering by batch rather than by biological groups.\n\n")

  if (viewer_available && interactive()) {
    # Try to open in viewer
    tryCatch(
      {
        if (Sys.info()["sysname"] == "Windows") {
          shell.exec(pca_plot_path)
        } else if (Sys.info()["sysname"] == "Darwin") {
          system(paste("open", shQuote(pca_plot_path)))
        } else {
          system(paste("xdg-open", shQuote(pca_plot_path)))
        }
        cat("PCA plot opened in external viewer.\n")
      },
      error = function(e) {
        cat("Could not open plot automatically.\n")
      }
    )
  }

  cat("PCA plot location:", pca_plot_path, "\n")
  cat("Additional PCA results available in the pca_results folder.\n\n")
}

#' Collect batch information from user
#'
#' @description
#' Interactively collects batch information for each sample
#'
#' @param sample_info Sample information data frame
#' @param sample_col Sample column name, default "Sample"
#'
#' @return Data frame with sample and batch information
#'
#' @export
collect_batch_info <- function(sample_info, sample_col = "Sample") {
  # Extract sample names
  if (sample_col %in% colnames(sample_info)) {
    sample_names <- sample_info[[sample_col]]
  } else {
    sample_names <- rownames(sample_info)
  }

  n_samples <- length(sample_names)

  cat("\n=== Batch Information Collection ===\n")
  cat("You have", n_samples, "samples.\n")
  cat("Please assign each sample to a batch.\n\n")

  # Ask for batch assignment method
  cat("How would you like to assign batches?\n")
  cat("1. Enter batch for each sample individually\n")
  cat("2. Enter batch assignments as a comma-separated list\n")
  cat("3. Samples are already in batch order (specify number of batches)\n")
  cat("4. Load from a file\n")

  method <- readline("Choose method (1-4): ")

  batch_info <- NULL

  if (method == "1") {
    # Individual entry
    batches <- character(n_samples)
    unique_batches <- character()

    for (i in 1:n_samples) {
      if (length(unique_batches) > 0) {
        cat("\nExisting batches:", paste(unique_batches, collapse = ", "), "\n")
      }
      batch <- readline(paste0("Batch for ", sample_names[i], ": "))
      batches[i] <- batch
      if (!batch %in% unique_batches) {
        unique_batches <- c(unique_batches, batch)
      }
    }

    batch_info <- data.frame(
      Sample = sample_names,
      Batch = batches,
      stringsAsFactors = FALSE
    )
  } else if (method == "2") {
    # Comma-separated list
    cat("\nEnter batch assignments as comma-separated values.\n")
    cat("Example: batch1,batch1,batch2,batch2,batch3\n")
    cat(
      "Order should match:", paste(sample_names[1:min(3, n_samples)], collapse = ", "),
      ifelse(n_samples > 3, "...", ""), "\n"
    )

    batch_string <- readline("Batch assignments: ")
    batches <- trimws(strsplit(batch_string, ",")[[1]])

    if (length(batches) != n_samples) {
      stop(
        "Number of batch assignments (", length(batches),
        ") does not match number of samples (", n_samples, ")"
      )
    }

    batch_info <- data.frame(
      Sample = sample_names,
      Batch = batches,
      stringsAsFactors = FALSE
    )
  } else if (method == "3") {
    # Samples in batch order
    n_batches <- as.integer(readline("Number of batches: "))

    if (n_batches <= 0 || n_batches > n_samples) {
      stop("Invalid number of batches")
    }

    # Distribute samples across batches
    batches <- rep(paste0("batch", 1:n_batches), each = ceiling(n_samples / n_batches))[1:n_samples]

    batch_info <- data.frame(
      Sample = sample_names,
      Batch = batches,
      stringsAsFactors = FALSE
    )

    # Show assignment for confirmation
    cat("\nProposed batch assignment:\n")
    print(table(batch_info$Batch))
  } else if (method == "4") {
    # Load from file
    file_path <- readline("Enter path to batch file (CSV with Sample and Batch columns): ")

    if (!file.exists(file_path)) {
      stop("File not found: ", file_path)
    }

    batch_data <- read.csv(file_path, stringsAsFactors = FALSE)

    if (!all(c("Sample", "Batch") %in% colnames(batch_data))) {
      stop("Batch file must contain 'Sample' and 'Batch' columns")
    }

    # Match samples
    batch_info <- data.frame(
      Sample = sample_names,
      Batch = batch_data$Batch[match(sample_names, batch_data$Sample)],
      stringsAsFactors = FALSE
    )

    if (any(is.na(batch_info$Batch))) {
      missing <- sample_names[is.na(batch_info$Batch)]
      stop("Batch information missing for samples: ", paste(missing, collapse = ", "))
    }
  } else {
    stop("Invalid method selection")
  }

  # Display summary
  cat("\n=== Batch Assignment Summary ===\n")
  batch_table <- table(batch_info$Batch)
  for (batch in names(batch_table)) {
    cat(batch, ":", batch_table[batch], "samples\n")
  }

  # Confirm
  confirm <- readline("\nProceed with these batch assignments? (y/n): ")
  if (!tolower(confirm) %in% c("y", "yes")) {
    stop("Batch assignment cancelled by user")
  }

  return(batch_info)
}

#' Remove batch effects using ComBat
#'
#' @description
#' Removes batch effects from proteomics data using the ComBat algorithm
#'
#' @param expression_data Expression data (with Accession column)
#' @param batch_info Batch information data frame
#' @param sample_info Sample information including group assignments
#' @param ref_batch Reference batch (optional)
#' @param group_col Group column name in sample_info, default "Group"
#' @param id_col ID column name in expression data, default "Accession"
#' @param log_transform Whether to log-transform data, default TRUE
#' @param epsilon Small value to add before log transformation, default 1e-6
#'
#' @return Batch-corrected expression data
#'
#' @export
remove_batch_effects <- function(expression_data,
                                 batch_info,
                                 sample_info,
                                 ref_batch = NULL,
                                 group_col = "Group",
                                 id_col = "Accession",
                                 log_transform = TRUE,
                                 epsilon = 1e-6) {
  # Validate inputs
  if (!id_col %in% colnames(expression_data)) {
    stop("ID column '", id_col, "' not found in expression data")
  }

  if (!group_col %in% colnames(sample_info)) {
    stop("Group column '", group_col, "' not found in sample info")
  }

  # Prepare data
  expr_matrix <- expression_data
  protein_ids <- expr_matrix[[id_col]]
  expr_matrix <- expr_matrix[, !colnames(expr_matrix) %in% id_col, drop = FALSE]

  # Match sample order
  common_samples <- intersect(colnames(expr_matrix), batch_info$Sample)
  if (length(common_samples) == 0) {
    stop("No common samples found between expression data and batch info")
  }

  expr_matrix <- expr_matrix[, common_samples, drop = FALSE]
  batch_vector <- batch_info$Batch[match(common_samples, batch_info$Sample)]

  # Get group information
  if ("Sample" %in% colnames(sample_info)) {
    group_vector <- sample_info[[group_col]][match(common_samples, sample_info$Sample)]
  } else {
    group_vector <- sample_info[[group_col]][match(common_samples, rownames(sample_info))]
  }

  # Check for missing values
  if (any(is.na(batch_vector))) {
    stop("Missing batch information for some samples")
  }

  if (any(is.na(group_vector))) {
    stop("Missing group information for some samples")
  }

  # Log transform if requested
  if (log_transform) {
    cat("Log2-transforming data...\n")
    expr_matrix <- log2(expr_matrix + epsilon)
  }

  # Check for variance in batches
  if (length(unique(batch_vector)) < 2) {
    warning("Only one batch detected. No batch correction needed.")
    corrected_matrix <- expr_matrix
  } else {
    # Run ComBat
    cat("Running ComBat batch correction...\n")
    cat("Batches:", paste(unique(batch_vector), collapse = ", "), "\n")
    if (!is.null(ref_batch)) {
      cat("Reference batch:", ref_batch, "\n")
    }

    # Create model matrix
    mod <- model.matrix(~ factor(group_vector))

    # Run ComBat with error handling
    tryCatch(
      {
        corrected_matrix <- ComBat(
          dat = as.matrix(expr_matrix),
          batch = batch_vector,
          mod = mod,
          ref.batch = ref_batch
        )
      },
      error = function(e) {
        stop(
          "ComBat failed: ", e$message,
          "\nCheck that each batch contains multiple samples and groups are not confounded with batches."
        )
      }
    )
  }

  # Back-transform if needed
  if (log_transform) {
    cat("Back-transforming data...\n")
    corrected_matrix <- 2^corrected_matrix
    # Set very small values to zero
    corrected_matrix[corrected_matrix <= 2 * epsilon] <- 0
  }

  # Reconstruct data frame
  corrected_data <- as.data.frame(corrected_matrix)
  corrected_data <- cbind(
    data.frame(Accession = protein_ids),
    corrected_data
  )

  return(corrected_data)
}

#' Visualize batch effects before and after correction
#'
#' @description
#' Creates comparison plots showing batch effects before and after correction
#'
#' @param original_data Original expression data
#' @param corrected_data Batch-corrected expression data
#' @param batch_info Batch information
#' @param sample_info Sample information
#' @param output_dir Output directory
#' @param id_col ID column name, default "Accession"
#' @param group_col Group column name, default "Group"
#' @param plot_width Plot width, default 12
#' @param plot_height Plot height, default 10
#'
#' @return List of plots
#'
#' @export
visualize_batch_correction <- function(original_data,
                                       corrected_data,
                                       batch_info,
                                       sample_info,
                                       output_dir,
                                       id_col = "Accession",
                                       group_col = "Group",
                                       plot_width = 12,
                                       plot_height = 10) {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Prepare data for PCA
  prep_data_for_pca <- function(data, id_col) {
    expr_mat <- data[, !colnames(data) %in% id_col, drop = FALSE]
    # Remove proteins with zero variance
    var_check <- apply(expr_mat, 1, var, na.rm = TRUE)
    expr_mat <- expr_mat[var_check > 0, , drop = FALSE]
    return(expr_mat)
  }

  orig_matrix <- prep_data_for_pca(original_data, id_col)
  corr_matrix <- prep_data_for_pca(corrected_data, id_col)

  # Ensure same samples
  common_samples <- intersect(colnames(orig_matrix), colnames(corr_matrix))
  orig_matrix <- orig_matrix[, common_samples]
  corr_matrix <- corr_matrix[, common_samples]

  # Prepare metadata
  meta_data <- merge(
    batch_info,
    sample_info,
    by.x = "Sample",
    by.y = ifelse("Sample" %in% colnames(sample_info), "Sample", "row.names"),
    all.x = TRUE
  )
  meta_data <- meta_data[match(common_samples, meta_data$Sample), ]

  # Perform PCA
  pca_original <- prcomp(t(log2(orig_matrix + 1e-6)), scale. = TRUE, center = TRUE)
  pca_corrected <- prcomp(t(log2(corr_matrix + 1e-6)), scale. = TRUE, center = TRUE)

  # Create PCA data frames
  create_pca_df <- function(pca_result, meta_data, label) {
    df <- as.data.frame(pca_result$x[, 1:3])
    df$Sample <- rownames(df)
    df <- merge(df, meta_data, by = "Sample")
    df$Data <- label

    # Calculate variance explained
    var_explained <- round(100 * pca_result$sdev^2 / sum(pca_result$sdev^2), 1)
    attr(df, "var_explained") <- var_explained

    return(df)
  }

  pca_df_orig <- create_pca_df(pca_original, meta_data, "Original")
  pca_df_corr <- create_pca_df(pca_corrected, meta_data, "Corrected")

  # Combined plot
  pca_combined <- rbind(pca_df_orig, pca_df_corr)

  # Create plots
  var_orig <- attr(pca_df_orig, "var_explained")
  var_corr <- attr(pca_df_corr, "var_explained")

  # 1. Side-by-side PCA colored by batch
  p_batch <- ggplot(pca_combined, aes(x = PC1, y = PC2, color = Batch)) +
    geom_point(size = 3, alpha = 0.7) +
    facet_wrap(~Data, scales = "free") +
    theme_bw() +
    theme(legend.position = "bottom") +
    labs(
      title = "PCA Comparison: Batch Effects",
      subtitle = "Color indicates batch assignment"
    )

  # Add variance explained to facet labels
  p_batch <- p_batch +
    geom_text(
      data = data.frame(
        Data = c("Original", "Corrected"),
        x = c(Inf, Inf),
        y = c(Inf, Inf),
        label = c(
          paste0("PC1: ", var_orig[1], "%, PC2: ", var_orig[2], "%"),
          paste0("PC1: ", var_corr[1], "%, PC2: ", var_corr[2], "%")
        )
      ), aes(x = x, y = y, label = label),
      hjust = 1.1, vjust = 1.5, size = 3, inherit.aes = FALSE
    )

  # 2. Side-by-side PCA colored by group
  p_group <- ggplot(pca_combined, aes(x = PC1, y = PC2, color = .data[[group_col]])) +
    geom_point(size = 3, alpha = 0.7) +
    facet_wrap(~Data, scales = "free") +
    theme_bw() +
    theme(legend.position = "bottom") +
    labs(
      title = "PCA Comparison: Biological Groups",
      subtitle = "Color indicates biological group"
    )

  # 3. Boxplot of first PC by batch
  p_boxplot <- ggplot(pca_combined, aes(x = Batch, y = PC1, fill = Batch)) +
    geom_boxplot(alpha = 0.7) +
    geom_point(position = position_jitter(width = 0.2), size = 2, alpha = 0.5) +
    facet_wrap(~Data, scales = "free_y") +
    theme_bw() +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      legend.position = "none"
    ) +
    labs(
      title = "PC1 Distribution by Batch",
      subtitle = "Batch effects should be reduced after correction"
    )

  # Save plots
  ggsave(
    filename = file.path(output_dir, "batch_correction_pca_by_batch.pdf"),
    plot = p_batch, width = plot_width, height = plot_height * 0.7
  )

  ggsave(
    filename = file.path(output_dir, "batch_correction_pca_by_group.pdf"),
    plot = p_group, width = plot_width, height = plot_height * 0.7
  )

  ggsave(
    filename = file.path(output_dir, "batch_correction_pc1_boxplot.pdf"),
    plot = p_boxplot, width = plot_width, height = plot_height * 0.6
  )

  # Combined plot
  library(cowplot)
  p_combined <- plot_grid(
    p_batch, p_group, p_boxplot,
    ncol = 1,
    rel_heights = c(1, 1, 0.7),
    labels = c("A", "B", "C")
  )

  ggsave(
    filename = file.path(output_dir, "batch_correction_summary.pdf"),
    plot = p_combined, width = plot_width, height = plot_height * 1.5
  )

  cat("Batch correction visualization saved to:", output_dir, "\n")

  return(list(
    pca_batch = p_batch,
    pca_group = p_group,
    boxplot = p_boxplot,
    combined = p_combined
  ))
}