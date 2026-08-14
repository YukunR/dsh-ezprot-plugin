library(dplyr)
library(reshape2)
library(car)
library(tidyverse)
library(stringr)
library(tidyr)
library(progress)
library(broom)

#' Perform t-test analysis for proteomics data
#'
#' @description
#' Performs t-test analysis between control and treatment groups with optional normality
#' and equal variance testing, multiple testing correction, and progress tracking
#'
#' @param expression_data Expression data matrix (proteins × samples) with ID column
#' @param sample_info Sample information data frame
#' @param control_group Name of control group
#' @param treatment_group Name of treatment group (optional, uses all non-control if NULL)
#' @param id_col ID column name in expression data, default "Accession"
#' @param sample_col Sample column name in sample_info, default "Sample"
#' @param group_col Group column name in sample_info, default "Group"
#' @param normality_test Whether to perform normality test, default FALSE
#' @param equal_variance_test Whether to perform equal variance test, default TRUE
#' @param multiple_test_correction Multiple testing correction method, default "fdr"
#' @param alternative Alternative hypothesis for t-test: "two.sided", "less", "greater", default "two.sided"
#' @param min_samples_per_group Minimum samples required per group, default 2
#' @param show_progress Whether to show progress bar, default TRUE
#' @param log_transform Whether to log transform data before testing, default FALSE
#'
#' @return Data frame with test results including p-values, fold changes, and adjusted p-values
#'
#' @export
perform_ttest_analysis <- function(expression_data,
                                   sample_info,
                                   control_group,
                                   treatment_group = NULL,
                                   id_col = "Accession",
                                   sample_col = "Sample",
                                   group_col = "Group",
                                   normality_test = FALSE,
                                   equal_variance_test = TRUE,
                                   multiple_test_correction = "fdr",
                                   alternative = "two.sided",
                                   min_samples_per_group = 2,
                                   show_progress = TRUE,
                                   log_transform = FALSE) {
  # Input validation
  if (!is.data.frame(expression_data) || !is.data.frame(sample_info)) {
    stop("Both expression_data and sample_info must be data frames")
  }

  if (!id_col %in% colnames(expression_data)) {
    stop(paste("ID column", id_col, "not found in expression_data"))
  }

  required_cols <- c(sample_col, group_col)
  missing_cols <- setdiff(required_cols, colnames(sample_info))
  if (length(missing_cols) > 0) {
    stop(paste("Missing columns in sample_info:", paste(missing_cols, collapse = ", ")))
  }

  # Check if control group exists
  available_groups <- unique(sample_info[[group_col]])
  if (!control_group %in% available_groups) {
    stop(paste(
      "Control group", control_group, "not found. Available groups:",
      paste(available_groups, collapse = ", ")
    ))
  }

  # Determine treatment group
  if (is.null(treatment_group)) {
    treatment_groups <- setdiff(available_groups, control_group)
    if (length(treatment_groups) != 1) {
      stop("Multiple non-control groups found. Please specify treatment_group explicitly.")
    }
    treatment_group <- treatment_groups[1]
  }

  if (!treatment_group %in% available_groups) {
    stop(paste(
      "Treatment group", treatment_group, "not found. Available groups:",
      paste(available_groups, collapse = ", ")
    ))
  }

  cat("Performing t-test analysis:\n")
  cat("Control group:", control_group, "\n")
  cat("Treatment group:", treatment_group, "\n")

  # Prepare data
  expr_matrix <- expression_data
  rownames(expr_matrix) <- expr_matrix[[id_col]]
  expr_matrix <- expr_matrix[, !colnames(expr_matrix) %in% id_col, drop = FALSE]

  # Filter to relevant samples
  relevant_samples <- sample_info[[sample_col]][sample_info[[group_col]] %in% c(control_group, treatment_group)]
  common_samples <- intersect(relevant_samples, colnames(expr_matrix))

  if (length(common_samples) == 0) {
    stop("No common samples found between expression data and sample info")
  }

  expr_matrix <- expr_matrix[, common_samples, drop = FALSE]
  sample_info_filtered <- sample_info[sample_info[[sample_col]] %in% common_samples, ]

  # Check sample counts
  control_samples <- sample_info_filtered[[sample_col]][sample_info_filtered[[group_col]] == control_group]
  treatment_samples <- sample_info_filtered[[sample_col]][sample_info_filtered[[group_col]] == treatment_group]

  if (length(control_samples) < min_samples_per_group || length(treatment_samples) < min_samples_per_group) {
    stop(paste(
      "Insufficient samples. Need at least", min_samples_per_group, "samples per group.",
      "Found:", length(control_samples), "control,", length(treatment_samples), "treatment"
    ))
  }

  cat("Sample counts - Control:", length(control_samples), ", Treatment:", length(treatment_samples), "\n")

  # Log transform if requested
  if (log_transform) {
    expr_matrix <- log2(expr_matrix + 1)
    cat("Applied log2(x+1) transformation\n")
  }

  # Convert to long format for analysis
  expr_long <- expr_matrix
  expr_long[[id_col]] <- rownames(expr_long)
  expr_long <- melt(expr_long,
    id.vars = id_col,
    variable.name = sample_col,
    value.name = "Abundance"
  )

  # Merge with sample info
  expr_long <- merge(expr_long, sample_info_filtered,
    by = sample_col,
    all.x = TRUE
  )

  # Remove rows with missing values
  expr_long <- expr_long[!is.na(expr_long$Abundance), ]

  # Get unique proteins
  unique_proteins <- unique(expr_long[[id_col]])
  n_proteins <- length(unique_proteins)

  cat("Analyzing", n_proteins, "proteins\n")

  # Initialize progress bar
  if (show_progress) {
    pb <- progress_bar$new(
      format = "Testing proteins [:bar] :percent :eta",
      total = n_proteins,
      clear = FALSE,
      width = 60
    )
  }

  # Initialize results list
  results_list <- list()

  # Perform tests for each protein
  for (i in seq_along(unique_proteins)) {
    protein_id <- unique_proteins[i]

    # Update progress bar
    if (show_progress) {
      pb$tick()
    }

    # Get data for this protein
    protein_data <- expr_long[expr_long[[id_col]] == protein_id, ]

    # Skip if insufficient data
    control_values <- protein_data$Abundance[protein_data[[group_col]] == control_group]
    treatment_values <- protein_data$Abundance[protein_data[[group_col]] == treatment_group]

    if (length(control_values) < 2 || length(treatment_values) < 2) {
      next
    }

    # Remove missing values
    control_values <- control_values[!is.na(control_values)]
    treatment_values <- treatment_values[!is.na(treatment_values)]

    if (length(control_values) < 2 || length(treatment_values) < 2) {
      next
    }

    # Initialize test parameters
    var_equal <- TRUE
    normality_passed <- TRUE

    # Normality test
    if (normality_test) {
      shapiro_control <- ifelse(length(control_values) >= 3,
        shapiro.test(control_values)$p.value,
        1
      )
      shapiro_treatment <- ifelse(length(treatment_values) >= 3,
        shapiro.test(treatment_values)$p.value,
        1
      )
      normality_passed <- (shapiro_control > 0.05) && (shapiro_treatment > 0.05)
    }

    # Equal variance test
    if (equal_variance_test && length(control_values) >= 2 && length(treatment_values) >= 2) {
      # Use Levene's test
      combined_data <- data.frame(
        values = c(control_values, treatment_values),
        group = c(
          rep(control_group, length(control_values)),
          rep(treatment_group, length(treatment_values))
        )
      )

      levene_result <- tryCatch(
        {
          leveneTest(values ~ group, data = combined_data, center = mean)
        },
        error = function(e) {
          list(`Pr(>F)` = c(NA, 0.5)) # Default to equal variance if test fails
        }
      )

      var_equal <- levene_result$`Pr(>F)`[1] > 0.05
      levene_p <- levene_result$`Pr(>F)`[1]
    } else {
      levene_p <- NA
    }

    # Perform appropriate test
    if (normality_test && !normality_passed) {
      # Use Wilcoxon test for non-normal data
      test_result <- tryCatch(
        {
          wilcox.test(treatment_values, control_values, alternative = alternative)
        },
        error = function(e) {
          list(p.value = NA, statistic = NA)
        }
      )
      test_method <- "wilcoxon"
    } else {
      # Use t-test
      test_result <- tryCatch(
        {
          t.test(treatment_values, control_values,
            var.equal = var_equal,
            alternative = alternative
          )
        },
        error = function(e) {
          list(p.value = NA, statistic = NA, parameter = NA)
        }
      )
      test_method <- ifelse(var_equal, "t_test_equal_var", "t_test_welch")
    }

    # Calculate fold change and other statistics
    control_mean <- mean(control_values, na.rm = TRUE)
    treatment_mean <- mean(treatment_values, na.rm = TRUE)
    fold_change <- treatment_mean / control_mean
    log2_fc <- log2(fold_change)

    # Store results
    results_list[[i]] <- data.frame(
      protein_id = protein_id,
      control_mean = control_mean,
      treatment_mean = treatment_mean,
      fold_change = fold_change,
      log2_fold_change = log2_fc,
      p_value = test_result$p.value,
      test_method = test_method,
      levene_p = levene_p,
      n_control = length(control_values),
      n_treatment = length(treatment_values),
      stringsAsFactors = FALSE
    )
  }

  # Combine results
  if (length(results_list) == 0) {
    stop("No valid proteins found for analysis")
  }

  results_df <- do.call(rbind, results_list)

  # Remove rows with missing p-values
  results_df <- results_df[!is.na(results_df$p_value), ]

  if (nrow(results_df) == 0) {
    stop("No valid test results obtained")
  }

  # Multiple testing correction
  if (multiple_test_correction == "bonferroni") {
    results_df$p_adjusted <- p.adjust(results_df$p_value, method = "bonferroni")
  } else if (multiple_test_correction == "fdr") {
    results_df$p_adjusted <- p.adjust(results_df$p_value, method = "fdr")
  } else if (multiple_test_correction == "none") {
    results_df$p_adjusted <- results_df$p_value
  } else {
    results_df$p_adjusted <- p.adjust(results_df$p_value, method = multiple_test_correction)
  }

  # Add significance indicators
  results_df$significant_05 <- results_df$p_adjusted < 0.05
  results_df$significant_01 <- results_df$p_adjusted < 0.01
  results_df$significant_001 <- results_df$p_adjusted < 0.001

  # Rename ID column
  colnames(results_df)[colnames(results_df) == "protein_id"] <- id_col

  # Sort by p-value
  results_df <- results_df[order(results_df$p_value), ]
  rownames(results_df) <- NULL

  # Print summary
  cat("\nT-test analysis completed:\n")
  cat("Total proteins tested:", nrow(results_df), "\n")
  cat("Significant proteins (p.adj < 0.05):", sum(results_df$significant_05, na.rm = TRUE), "\n")
  cat("Significant proteins (p.adj < 0.01):", sum(results_df$significant_01, na.rm = TRUE), "\n")
  cat("Multiple testing correction:", multiple_test_correction, "\n")

  if (normality_test) {
    cat("Normality testing: enabled\n")
    cat("Wilcoxon tests performed:", sum(results_df$test_method == "wilcoxon", na.rm = TRUE), "\n")
  } else {
    cat("Normality testing: disabled (assuming normal distribution)\n")
  }

  if (equal_variance_test) {
    cat("Equal variance testing: enabled\n")
    welch_tests <- sum(results_df$test_method == "t_test_welch", na.rm = TRUE)
    equal_var_tests <- sum(results_df$test_method == "t_test_equal_var", na.rm = TRUE)
    cat("Welch's t-tests:", welch_tests, "\n")
    cat("Equal variance t-tests:", equal_var_tests, "\n")
  } else {
    cat("Equal variance testing: disabled (assuming equal variances)\n")
  }

  return(results_df)
}

#' Batch t-test analysis for multiple comparisons
#'
#' @description
#' Performs t-test analysis for multiple comparison groups generated by create_comparison_groups()
#'
#' @param comparison_groups List of comparison groups (output from create_comparison_groups)
#' @param normality_test Whether to perform normality test, default FALSE
#' @param equal_variance_test Whether to perform equal variance test, default TRUE
#' @param multiple_test_correction Multiple testing correction method, default "fdr"
#' @param alternative Alternative hypothesis, default "two.sided"
#' @param show_progress Whether to show progress bar, default TRUE
#' @param output_dir Directory to save results (optional)
#' @param save_results Whether to save results to CSV files, default FALSE
#'
#' @return Named list of t-test results for each comparison
#'
#' @export
batch_ttest_analysis <- function(comparison_groups,
                                 normality_test = FALSE,
                                 equal_variance_test = TRUE,
                                 multiple_test_correction = "fdr",
                                 alternative = "two.sided",
                                 show_progress = TRUE,
                                 output_dir = NULL,
                                 save_results = FALSE) {
  if (length(comparison_groups) == 0) {
    stop("No comparison groups provided")
  }

  cat("=== Batch T-test Analysis ===\n")
  cat("Number of comparisons:", length(comparison_groups), "\n")
  cat("Normality testing:", ifelse(normality_test, "enabled", "disabled"), "\n")
  cat("Equal variance testing:", ifelse(equal_variance_test, "enabled", "disabled"), "\n")
  cat("Multiple testing correction:", multiple_test_correction, "\n\n")

  # Create output directory if saving results
  if (save_results && !is.null(output_dir)) {
    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }
  }

  # Initialize results list
  all_results <- list()

  # Process each comparison
  for (comp_name in names(comparison_groups)) {
    cat("Processing comparison:", comp_name, "\n")

    comp_data <- comparison_groups[[comp_name]]

    # Perform t-test
    ttest_result <- perform_ttest_analysis(
      expression_data = comp_data$expression_data,
      sample_info = comp_data$sample_info,
      control_group = comp_data$control_name,
      treatment_group = comp_data$treatment_name,
      normality_test = normality_test,
      equal_variance_test = equal_variance_test,
      multiple_test_correction = multiple_test_correction,
      alternative = alternative,
      show_progress = show_progress
    )

    # Add comparison info
    ttest_result$comparison_name <- comp_name
    ttest_result$control_group <- comp_data$control_name
    ttest_result$treatment_group <- comp_data$treatment_name

    # Store results
    all_results[[comp_name]] <- ttest_result

    # Save individual results if requested
    if (save_results && !is.null(output_dir)) {
      filename <- file.path(output_dir, paste0("ttest_", comp_name, ".csv"))
      write.csv(ttest_result, filename, row.names = FALSE)
      cat("Results saved to:", filename, "\n")
    }

    cat("\n")
  }

  # Create combined results summary
  summary_stats <- data.frame(
    Comparison = names(all_results),
    Control = sapply(all_results, function(x) x$control_group[1]),
    Treatment = sapply(all_results, function(x) x$treatment_group[1]),
    Total_Proteins = sapply(all_results, nrow),
    Significant_05 = sapply(all_results, function(x) sum(x$significant_05, na.rm = TRUE)),
    Significant_01 = sapply(all_results, function(x) sum(x$significant_01, na.rm = TRUE)),
    Significant_001 = sapply(all_results, function(x) sum(x$significant_001, na.rm = TRUE)),
    stringsAsFactors = FALSE
  )

  cat("=== Batch Analysis Summary ===\n")
  print(summary_stats)

  # Save summary if requested
  if (save_results && !is.null(output_dir)) {
    summary_file <- file.path(output_dir, "ttest_summary.csv")
    write.csv(summary_stats, summary_file, row.names = FALSE)
    cat("\nSummary saved to:", summary_file, "\n")
  }

  # Return results with summary
  return(list(
    results = all_results,
    summary = summary_stats
  ))
}