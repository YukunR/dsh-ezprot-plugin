library(PCAtools)
library(corrplot)
library(pheatmap)
library(ggforce)
library(tidyverse)
library(ggplot2)
library(cowplot)
library(RColorBrewer)
library(viridis)
library(ggdendro)

#' Prepare data for PCA analysis
#'
#' @description
#' Prepares expression data and sample information for PCA analysis
#'
#' @param expression_data Expression data matrix or data frame
#' @param sample_info Sample information data frame
#' @param id_col ID column name in expression data, default "Accession"
#' @param sample_col Sample column name in sample_info, default "Sample"
#' @param remove_na_samples Whether to remove samples with too many NAs, default TRUE
#' @param na_threshold Maximum proportion of NAs allowed per sample, default 0.5
#'
#' @return List containing prepared expression matrix and sample metadata
#'
#' @export
prepare_pca_data <- function(expression_data,
                             sample_info,
                             id_col = "Accession",
                             sample_col = "Sample",
                             remove_na_samples = TRUE,
                             na_threshold = 0.5) {
  # Prepare expression data
  if (id_col %in% colnames(expression_data)) {
    expr_matrix <- expression_data
    rownames(expr_matrix) <- expr_matrix[[id_col]]
    expr_matrix <- expr_matrix[, !colnames(expr_matrix) %in% id_col, drop = FALSE]
  } else {
    expr_matrix <- expression_data
  }

  # Prepare sample info
  if (sample_col %in% colnames(sample_info)) {
    sample_meta <- sample_info
    rownames(sample_meta) <- sample_meta[[sample_col]]
    sample_meta <- sample_meta[, !colnames(sample_meta) %in% sample_col, drop = FALSE]
  } else {
    sample_meta <- sample_info
  }

  # Check sample consistency
  common_samples <- intersect(colnames(expr_matrix), rownames(sample_meta))
  if (length(common_samples) == 0) {
    stop("No common samples found between expression data and sample info")
  }

  # Filter to common samples
  expr_matrix <- expr_matrix[, common_samples, drop = FALSE]
  sample_meta <- sample_meta[common_samples, , drop = FALSE]

  # Remove samples with too many NAs if requested
  if (remove_na_samples) {
    na_proportions <- colSums(is.na(expr_matrix)) / nrow(expr_matrix)
    good_samples <- names(na_proportions)[na_proportions <= na_threshold]

    if (length(good_samples) < 3) {
      warning("Less than 3 samples remain after NA filtering. Proceeding with all samples.")
    } else {
      expr_matrix <- expr_matrix[, good_samples, drop = FALSE]
      sample_meta <- sample_meta[good_samples, , drop = FALSE]
      cat(
        "Removed", length(common_samples) - length(good_samples), "samples with >",
        na_threshold * 100, "% missing values\n"
      )
    }
  }

  # Remove proteins with all NAs
  complete_proteins <- rowSums(!is.na(expr_matrix)) > 0
  expr_matrix <- expr_matrix[complete_proteins, , drop = FALSE]

  cat("Final data dimensions:", nrow(expr_matrix), "proteins ×", ncol(expr_matrix), "samples\n")

  return(list(
    expression_matrix = expr_matrix,
    sample_metadata = sample_meta
  ))
}

#' Create correlation heatmap and dendrogram
#'
#' @description
#' Generates sample correlation heatmap and hierarchical clustering dendrogram
#'
#' @param expression_matrix Expression data matrix (proteins × samples)
#' @param sample_metadata Sample metadata
#' @param group_colors Named vector of group colors (optional)
#' @param output_dir Output directory
#' @param group_col Group column name in metadata, default "Group"
#' @param correlation_method Correlation method: "pearson", "spearman", default "pearson"
#' @param clustering_method Clustering method for dendrogram, default "complete"
#' @param plot_width Plot width, default 8
#' @param plot_height Plot height, default 8
#'
#' @return List containing correlation matrix and plots
#'
#' @export
create_correlation_analysis <- function(expression_matrix,
                                        sample_metadata,
                                        group_colors = NULL,
                                        output_dir = "./",
                                        group_col = "Group",
                                        correlation_method = "pearson",
                                        clustering_method = "complete",
                                        plot_width = 8,
                                        plot_height = 8) {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Calculate correlation matrix
  cor_matrix <- cor(expression_matrix, use = "complete.obs", method = correlation_method)

  # Prepare annotation for heatmap
  if (group_col %in% colnames(sample_metadata)) {
    annotation_df <- data.frame(
      Group = sample_metadata[[group_col]],
      row.names = rownames(sample_metadata)
    )

    # Prepare annotation colors
    if (!is.null(group_colors)) {
      if (is.list(group_colors) && "group_colors" %in% names(group_colors)) {
        annotation_colors <- list(Group = group_colors$group_colors)
      } else {
        annotation_colors <- list(Group = group_colors)
      }
    } else {
      # Generate default colors
      unique_groups <- unique(sample_metadata[[group_col]])
      if (length(unique_groups) <= 8) {
        default_colors <- RColorBrewer::brewer.pal(max(3, length(unique_groups)), "Set2")
      } else {
        default_colors <- rainbow(length(unique_groups))
      }
      names(default_colors) <- unique_groups
      annotation_colors <- list(Group = default_colors)
    }
  } else {
    annotation_df <- NULL
    annotation_colors <- NULL
  }

  # Create correlation heatmap
  cor_heatmap <- pheatmap(
    cor_matrix,
    cluster_rows = TRUE,
    cluster_cols = TRUE,
    annotation_col = annotation_df,
    annotation_colors = annotation_colors,
    color = colorRampPalette(c("blue", "white", "red"))(100),
    main = paste("Sample Correlation (", correlation_method, ")", sep = ""),
    fontsize = 10,
    fontsize_row = 8,
    fontsize_col = 8,
    silent = TRUE
  )

  # Save correlation heatmap
  ggsave(
    filename = file.path(output_dir, "sample_correlation_heatmap.pdf"),
    plot = cor_heatmap,
    width = plot_width, height = plot_height
  )
  # Plugin addition: PNG beside the PDF so the DSH chat can show it.
  ggsave(
    filename = file.path(output_dir, "sample_correlation_heatmap.png"),
    plot = cor_heatmap,
    width = plot_width, height = plot_height, dpi = 150
  )

  # Create dendrogram
  dist_matrix <- dist(t(expression_matrix))
  hc <- hclust(dist_matrix, method = clustering_method)

  pdf(
    file = file.path(output_dir, "sample_dendrogram.pdf"),
    width = plot_width, height = plot_height / 2
  )
  plot(hc,
    main = "Sample Hierarchical Clustering",
    xlab = "Samples",
    ylab = "Distance",
    cex = 0.8
  )
  dev.off()

  # Create a ggplot version of dendrogram with colors
  if (!is.null(annotation_df)) {
    library(ggdendro)

    # Convert to dendrogram
    dend_data <- dendro_data(hc)

    # Add group information to labels
    dend_labels <- dend_data$labels
    dend_labels$Group <- sample_metadata[[group_col]][match(dend_labels$label, rownames(sample_metadata))]

    # Create ggplot dendrogram
    gg_dend <- ggplot() +
      geom_segment(
        data = dend_data$segments,
        aes(x = x, y = y, xend = xend, yend = yend)
      ) +
      geom_text(
        data = dend_labels,
        aes(x = x, y = y, label = label, color = Group),
        hjust = 0.5, vjust = -1, angle = 90, size = 3
      ) +
      scale_color_manual(values = annotation_colors$Group) +
      theme_minimal() +
      theme(
        axis.text.x = element_blank(),
        axis.ticks.x = element_blank(),
        panel.grid = element_blank()
      ) +
      labs(
        title = "Sample Hierarchical Clustering",
        x = "Samples", y = "Distance"
      ) +
      coord_flip()

    ggsave(
      filename = file.path(output_dir, "sample_dendrogram_colored.pdf"),
      plot = gg_dend,
      width = plot_height, height = plot_width
    )
    # Plugin addition: PNG beside the PDF so the DSH chat can show it.
    ggsave(
      filename = file.path(output_dir, "sample_dendrogram_colored.png"),
      plot = gg_dend,
      width = plot_height, height = plot_width, dpi = 150
    )
  }

  cat("Correlation analysis completed:\n")
  cat("Heatmap:", file.path(output_dir, "sample_correlation_heatmap.pdf"), "\n")
  cat("Dendrogram:", file.path(output_dir, "sample_dendrogram.pdf"), "\n")

  return(list(
    correlation_matrix = cor_matrix,
    heatmap = cor_heatmap,
    dendrogram = hc
  ))
}

#' Perform comprehensive PCA analysis
#'
#' @description
#' Conducts PCA analysis with scree plot, biplot, and loading analysis
#'
#' @param expression_matrix Expression data matrix (proteins × samples)
#' @param sample_metadata Sample metadata
#' @param group_colors Named vector of group colors (optional)
#' @param output_dir Output directory
#' @param group_col Group column name in metadata, default "Group"
#' @param center Whether to center the data, default TRUE
#' @param scale Whether to scale the data, default TRUE
#' @param n_components Number of components to calculate, default 10
#' @param plot_width Plot width, default 10
#' @param plot_height Plot height, default 8
#'
#' @return PCA results object and plots
#'
#' @export
perform_pca_analysis <- function(expression_matrix,
                                 sample_metadata,
                                 group_colors = NULL,
                                 output_dir = "./",
                                 group_col = "Group",
                                 center = TRUE,
                                 scale = TRUE,
                                 n_components = 10,
                                 plot_width = 10,
                                 plot_height = 8) {
  # Create output directory
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }

  # Handle missing values for PCA
  expr_for_pca <- expression_matrix
  if (any(is.na(expr_for_pca))) {
    cat("Warning: Missing values detected. Using complete observations only.\n")
    complete_samples <- colSums(!is.na(expr_for_pca)) > nrow(expr_for_pca) * 0.5
    complete_proteins <- rowSums(!is.na(expr_for_pca)) > ncol(expr_for_pca) * 0.5
    expr_for_pca <- expr_for_pca[complete_proteins, complete_samples, drop = FALSE]
    sample_metadata <- sample_metadata[colnames(expr_for_pca), , drop = FALSE]
  }

  # Perform PCA using PCAtools
  pca_result <- pca(expr_for_pca,
    metadata = sample_metadata,
    center = center,
    scale = scale
  )

  # Extract group colors
  if (!is.null(group_colors)) {
    if (is.list(group_colors) && "group_colors" %in% names(group_colors)) {
      actual_group_colors <- group_colors$group_colors
    } else {
      actual_group_colors <- group_colors
    }
  } else {
    # Generate default colors
    unique_groups <- unique(sample_metadata[[group_col]])
    if (length(unique_groups) <= 8) {
      actual_group_colors <- RColorBrewer::brewer.pal(max(3, length(unique_groups)), "Set2")
    } else {
      actual_group_colors <- rainbow(length(unique_groups))
    }
    names(actual_group_colors) <- unique_groups
  }

  # 1. Scree plot
  scree_plot <- screeplot(pca_result,
    components = 1:min(n_components, ncol(pca_result$rotated)),
    title = "PCA Scree Plot",
    titleLabSize = 14,
    axisLabSize = 12
  ) +
    theme_bw() +
    theme(panel.grid.minor = element_blank())

  ggsave(
    filename = file.path(output_dir, "pca_screeplot.pdf"),
    plot = scree_plot,
    width = plot_width * 0.8, height = plot_height * 0.6
  )

  # 2. Variance explained barplot
  variance_explained <- pca_result$variance
  var_df <- data.frame(
    Component = factor(paste0("PC", 1:length(variance_explained)),
      levels = paste0("PC", 1:length(variance_explained))
    ),
    Variance = variance_explained
  )

  variance_plot <- ggplot(
    var_df[1:min(10, nrow(var_df)), ],
    aes(x = Component, y = Variance)
  ) +
    geom_bar(stat = "identity", fill = "steelblue", alpha = 0.7) +
    geom_text(aes(label = paste0(round(Variance, 1), "%")),
      vjust = -0.3, size = 3
    ) +
    theme_bw() +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1),
      panel.grid.minor = element_blank()
    ) +
    labs(
      title = "Variance Explained by Principal Components",
      x = "Principal Component",
      y = "Variance Explained (%)"
    )

  ggsave(
    filename = file.path(output_dir, "pca_variance_explained.pdf"),
    plot = variance_plot,
    width = plot_width * 0.8, height = plot_height * 0.6
  )
  # Plugin addition: PNG beside the PDF so the DSH chat can show it.
  ggsave(
    filename = file.path(output_dir, "pca_variance_explained.png"),
    plot = variance_plot,
    width = plot_width * 0.8, height = plot_height * 0.6, dpi = 150
  )

  # 3. PCA Biplot (PC1 vs PC2)
  pca_biplot <- biplot(pca_result,
    x = "PC1", y = "PC2",
    colby = group_col,
    colkey = actual_group_colors,
    encircle = TRUE,
    encircleFill = TRUE,
    encircleAlpha = 0.2,
    encircleLineSize = 1,
    pointSize = 3,
    labSize = 3,
    title = "PCA Biplot (PC1 vs PC2)",
    subtitle = paste0(
      "PC1: ", round(pca_result$variance[1], 1),
      "% variance, PC2: ", round(pca_result$variance[2], 1), "% variance"
    )
  ) +
    theme_bw() +
    theme(
      legend.position = "bottom",
      panel.grid.minor = element_blank()
    ) +
    coord_equal() +
    guides(color = guide_legend(title = group_col))

  ggsave(
    filename = file.path(output_dir, "pca_biplot_PC1_PC2.pdf"),
    plot = pca_biplot,
    width = plot_width, height = plot_height
  )
  # Plugin addition: PNG beside the PDF so the DSH chat can show it.
  ggsave(
    filename = file.path(output_dir, "pca_biplot_PC1_PC2.png"),
    plot = pca_biplot,
    width = plot_width, height = plot_height, dpi = 150
  )

  # 4. Additional PC combinations
  pc_combinations <- list(c("PC1", "PC3"), c("PC2", "PC3"))

  for (i in seq_along(pc_combinations)) {
    pc_pair <- pc_combinations[[i]]
    pc_plot <- biplot(pca_result,
      x = pc_pair[1], y = pc_pair[2],
      colby = group_col,
      colkey = actual_group_colors,
      encircle = TRUE,
      encircleFill = TRUE,
      encircleAlpha = 0.2,
      pointSize = 3,
      labSize = 3,
      title = paste("PCA Biplot (", pc_pair[1], "vs", pc_pair[2], ")"),
      subtitle = paste0(
        pc_pair[1], ": ", round(pca_result$variance[as.numeric(substr(pc_pair[1], 3, 3))], 1),
        "% variance, ", pc_pair[2], ": ",
        round(pca_result$variance[as.numeric(substr(pc_pair[2], 3, 3))], 1), "% variance"
      )
    ) +
      theme_bw() +
      theme(
        legend.position = "bottom",
        panel.grid.minor = element_blank()
      ) +
      coord_equal()

    ggsave(
      filename = file.path(output_dir, paste0("pca_biplot_", pc_pair[1], "_", pc_pair[2], ".pdf")),
      plot = pc_plot,
      width = plot_width, height = plot_height
    )
  }

  # 5. Loading plots
  loading_plot <- plotloadings(pca_result,
    components = 1:min(3, ncol(pca_result$loadings)),
    rangeRetain = 0.05,
    labSize = 2,
    title = "PCA Loadings",
    subtitle = "Top contributing variables",
    titleLabSize = 14,
    subtitleLabSize = 12
  ) +
    theme_bw()

  ggsave(
    filename = file.path(output_dir, "pca_loadings.pdf"),
    plot = loading_plot,
    width = plot_width, height = plot_height
  )

  # 6. Detailed loading heatmap for top contributors
  n_pcs <- min(5, ncol(pca_result$loadings))
  top_contributors <- unique(unlist(lapply(1:n_pcs, function(i) {
    pc_loadings <- abs(as.matrix(pca_result$loadings)[, i])
    names(pc_loadings)[order(pc_loadings, decreasing = TRUE)[1:min(20, length(pc_loadings))]]
  })))

  if (length(top_contributors) > 5) {
    loading_matrix <- pca_result$loadings[top_contributors, 1:min(5, ncol(pca_result$loadings)), drop = FALSE]

    loading_heatmap <- pheatmap(
      loading_matrix,
      cluster_rows = TRUE,
      cluster_cols = FALSE,
      color = colorRampPalette(c("blue", "white", "red"))(100),
      main = "Top Contributing Variables - PC Loadings",
      fontsize = 8,
      fontsize_row = 6,
      fontsize_col = 10,
      silent = TRUE
    )

    ggsave(
      filename = file.path(output_dir, "pca_loading_heatmap.pdf"),
      plot = loading_heatmap,
      width = plot_width * 0.8, height = plot_height
    )
  }

  # Print summary
  cat("PCA Analysis completed:\n")
  cat("Data dimensions:", nrow(expr_for_pca), "proteins ×", ncol(expr_for_pca), "samples\n")
  cat("Variance explained by first 3 PCs:", paste(round(pca_result$variance[1:3], 1), collapse = "%, "), "%\n")
  cat("Output files saved to:", output_dir, "\n")

  return(pca_result)
}

#' Comprehensive PCA workflow
#'
#' @description
#' Complete PCA analysis workflow including data preparation, correlation analysis, and PCA
#'
#' @param expression_data Expression data matrix or data frame
#' @param sample_info Sample information data frame
#' @param group_colors Named vector of group colors (from generate_sample_colors() or custom)
#' @param output_dir Output directory
#' @param id_col ID column name in expression data, default "Accession"
#' @param sample_col Sample column name in sample_info, default "Sample"
#' @param group_col Group column name in sample_info, default "Group"
#' @param correlation_method Correlation method, default "pearson"
#' @param center Whether to center data for PCA, default TRUE
#' @param scale Whether to scale data for PCA, default TRUE
#' @param plot_width Plot width, default 10
#' @param plot_height Plot height, default 8
#'
#' @return List containing all analysis results
#'
#' @export
run_comprehensive_pca <- function(expression_data,
                                  sample_info,
                                  group_colors = NULL,
                                  output_dir = "./",
                                  id_col = "Accession",
                                  sample_col = "Sample",
                                  group_col = "Group",
                                  correlation_method = "pearson",
                                  center = TRUE,
                                  scale = TRUE,
                                  plot_width = 10,
                                  plot_height = 8) {
  cat("=== Starting Comprehensive PCA Analysis ===\n\n")

  # Step 1: Prepare data
  cat("Step 1: Preparing data...\n")
  prepared_data <- prepare_pca_data(
    expression_data, sample_info,
    id_col, sample_col
  )

  # Step 2: Correlation analysis
  cat("\nStep 2: Correlation analysis...\n")
  correlation_results <- create_correlation_analysis(
    prepared_data$expression_matrix,
    prepared_data$sample_metadata,
    group_colors = group_colors,
    output_dir = output_dir,
    group_col = group_col,
    correlation_method = correlation_method,
    plot_width = plot_width,
    plot_height = plot_height
  )

  # Step 3: PCA analysis
  cat("\nStep 3: PCA analysis...\n")
  pca_results <- perform_pca_analysis(
    prepared_data$expression_matrix,
    prepared_data$sample_metadata,
    group_colors = group_colors,
    output_dir = output_dir,
    group_col = group_col,
    center = center,
    scale = scale,
    plot_width = plot_width,
    plot_height = plot_height
  )

  cat("\n=== PCA Analysis Complete ===\n")

  # Plugin addition: export machine-readable summaries for the DSH plugin
  tryCatch(
    {
      variance_df <- data.frame(
        Component = paste0("PC", seq_along(pca_results$variance)),
        Variance  = pca_results$variance,
        stringsAsFactors = FALSE
      )
      write.csv(variance_df,
        file.path(output_dir, "pca_results_summary.csv"),
        row.names = FALSE
      )
      if (!is.null(pca_results$rotated)) {
        write.csv(as.data.frame(pca_results$rotated),
          file.path(output_dir, "pca_sample_scores.csv")
        )
      }
    },
    error = function(e) warning("PCA summary export failed: ", e$message)
  )

  # Return comprehensive results
  return(list(
    prepared_data = prepared_data,
    correlation_results = correlation_results,
    pca_results = pca_results,
    summary = list(
      n_proteins = nrow(prepared_data$expression_matrix),
      n_samples = ncol(prepared_data$expression_matrix),
      variance_pc1_3 = round(pca_results$variance[1:3], 1),
      groups = unique(prepared_data$sample_metadata[[group_col]])
    )
  ))
}