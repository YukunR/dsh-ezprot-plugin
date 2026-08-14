# ==== Example usage ====
# Create all comparisons
# all_comparisons <- create_all_pairwise_comparisons(
#   expression_data = processed_data,
#   sample_info = sample_info,
#   control_groups = c("Control"),
#   exclude_groups = NULL
# )

# Control vs all other groups
# control_comparisons <- create_control_vs_all_comparisons(
#   expression_data = processed_data,
#   sample_info = sample_info,
#   control_group = "Control"
# )

# Control vs specific groups
# control_comparisons <- create_control_vs_all_comparisons(
#   expression_data = processed_data,
#   sample_info = sample_info,
#   control_group = "Control",
#   treatment_groups = c("Treatment_A", "High_dose")
# )

# Multiple groups as control or treatment
# comparisons <- list(
#   list(control = c("Healthy", "Control2"), treatment = "Sepsis", name = "Sepsis_vs_Combined"),
#   list(control = "Healthy", treatment = c("Sepsis", "SepsisAKI"), name = "AllSepsis_vs_Healthy")
# )

library(dplyr)
library(tidyr)

#' Generate comparison groups for differential analysis
#'
#' @description
#' Creates comparison groups by automatically selecting samples based on user-defined
#' control and treatment group combinations. Now supports multiple groups as control
#' or treatment - samples from multiple groups will be merged together.
#'
#' @param expression_data Expression data matrix (with or without ID column)
#' @param sample_info Sample information data frame
#' @param comparisons List of comparisons to perform. Each element should be a named list with:
#'   \itemize{
#'     \item control: Name(s) of control group(s) - can be a single name or a vector of names
#'     \item treatment: Name(s) of treatment group(s) - can be a single name or a vector of names
#'     \item name: Optional custom name for comparison (default: "treatment_vs_control")
#'   }
#' @param id_col ID column name in expression data, default "Accession"
#' @param sample_col Sample column name in sample_info, default "Sample"
#' @param group_col Group column name in sample_info, default "Group"
#' @param include_id_col Whether to include ID column in output, default TRUE
#'
#' @return Named list of comparison groups, each containing:
#'   \item{expression_data}{Filtered expression data for the comparison}
#'   \item{sample_info}{Filtered sample info for the comparison (with updated Group column)}
#'   \item{control_name}{Name of control group (merged name if multiple groups)}
#'   \item{treatment_name}{Name of treatment group (merged name if multiple groups)}
#'   \item{n_control}{Number of control samples}
#'   \item{n_treatment}{Number of treatment samples}
#'   \item{original_groups}{List with original group names for control and treatment}
#'
#' @export
#'
#' @examples
#' # Define comparisons - single groups
#' my_comparisons <- list(
#'   list(control = "Control", treatment = "Treatment_A"),
#'   list(control = "Control", treatment = "Treatment_B", name = "TreatB_vs_Ctrl"),
#'   list(control = "Treatment_A", treatment = "Treatment_B")
#' )
#'
#' # Define comparisons - multiple groups as control or treatment
#' my_comparisons <- list(
#'   list(control = c("Healthy", "Control2"), treatment = "Sepsis", name = "Sepsis_vs_Combined"),
#'   list(control = "Healthy", treatment = c("Sepsis", "SepsisAKI"), name = "AllSepsis_vs_Healthy")
#' )
#'
#' # Generate comparison groups
#' comparison_groups <- create_comparison_groups(
#'   expression_data = processed_data,
#'   sample_info = sample_info,
#'   comparisons = my_comparisons
#' )
create_comparison_groups <- function(expression_data,
                                     sample_info,
                                     comparisons,
                                     id_col = "Accession",
                                     sample_col = "Sample",
                                     group_col = "Group",
                                     include_id_col = TRUE) {
  # Input validation
  if (!is.list(comparisons)) {
    stop("'comparisons' must be a list")
  }

  if (!is.data.frame(sample_info)) {
    stop("'sample_info' must be a data frame")
  }

  # Check required columns
  required_cols <- c(sample_col, group_col)
  missing_cols <- setdiff(required_cols, colnames(sample_info))
  if (length(missing_cols) > 0) {
    stop(paste("Missing columns in sample_info:", paste(missing_cols, collapse = ", ")))
  }

  # Prepare expression data
  if (id_col %in% colnames(expression_data)) {
    expr_matrix <- expression_data
    has_id_col <- TRUE
  } else {
    expr_matrix <- expression_data
    has_id_col <- FALSE
  }

  # Get available groups
  available_groups <- unique(sample_info[[group_col]])
  cat("Available groups:", paste(available_groups, collapse = ", "), "\n\n")

  # Initialize results list
  comparison_results <- list()

  # Process each comparison
  for (i in seq_along(comparisons)) {
    comp <- comparisons[[i]]

    # Validate comparison structure
    if (!("control" %in% names(comp)) || !("treatment" %in% names(comp))) {
      stop(paste("Comparison", i, "must have 'control' and 'treatment' fields"))
    }

    # Get control and treatment groups (can be vectors)
    control_groups <- comp$control
    treatment_groups <- comp$treatment

    # Ensure they are character vectors
    control_groups <- as.character(control_groups)
    treatment_groups <- as.character(treatment_groups)

    # Check if all groups exist
    missing_control <- setdiff(control_groups, available_groups)
    if (length(missing_control) > 0) {
      stop(paste("Control group(s) not found in data:", paste(missing_control, collapse = ", ")))
    }

    missing_treatment <- setdiff(treatment_groups, available_groups)
    if (length(missing_treatment) > 0) {
      stop(paste("Treatment group(s) not found in data:", paste(missing_treatment, collapse = ", ")))
    }

    # Check for overlap between control and treatment groups
    overlap_groups <- intersect(control_groups, treatment_groups)
    if (length(overlap_groups) > 0) {
      stop(paste("Groups cannot be in both control and treatment:", paste(overlap_groups, collapse = ", ")))
    }

    # Generate merged group names for display
    if (length(control_groups) == 1) {
      control_name <- control_groups
    } else {
      control_name <- paste(control_groups, collapse = "+")
    }

    if (length(treatment_groups) == 1) {
      treatment_name <- treatment_groups
    } else {
      treatment_name <- paste(treatment_groups, collapse = "+")
    }

    # Generate comparison name
    if ("name" %in% names(comp) && !is.null(comp$name)) {
      comp_name <- comp$name
    } else {
      comp_name <- paste0(treatment_name, "_vs_", control_name)
    }

    # Get samples for each group
    control_samples <- sample_info[[sample_col]][sample_info[[group_col]] %in% control_groups]
    treatment_samples <- sample_info[[sample_col]][sample_info[[group_col]] %in% treatment_groups]

    # Combine samples for this comparison
    selected_samples <- c(control_samples, treatment_samples)

    # Check if samples exist in expression data
    if (has_id_col) {
      available_samples <- setdiff(colnames(expr_matrix), id_col)
    } else {
      available_samples <- colnames(expr_matrix)
    }

    valid_samples <- intersect(selected_samples, available_samples)
    missing_samples <- setdiff(selected_samples, available_samples)

    if (length(missing_samples) > 0) {
      warning(paste(
        "Missing samples in expression data for comparison", comp_name, ":",
        paste(missing_samples, collapse = ", ")
      ))
    }

    if (length(valid_samples) < 2) {
      warning(paste("Not enough valid samples for comparison", comp_name, ". Skipping."))
      next
    }

    # Filter expression data
    if (has_id_col && include_id_col) {
      filtered_expr <- expr_matrix[, c(id_col, valid_samples), drop = FALSE]
    } else {
      filtered_expr <- expr_matrix[, valid_samples, drop = FALSE]
    }

    # Filter sample info
    filtered_sample_info <- sample_info[sample_info[[sample_col]] %in% valid_samples, , drop = FALSE]

    # Store original group information before modifying
    original_group_info <- filtered_sample_info[[group_col]]

    # Update Group column to reflect merged groups
    # This is important for downstream t-test which uses Group column
    filtered_sample_info[[group_col]] <- ifelse(
      filtered_sample_info[[group_col]] %in% control_groups,
      control_name,
      treatment_name
    )

    # Count samples
    n_control <- sum(filtered_sample_info[[group_col]] == control_name)
    n_treatment <- sum(filtered_sample_info[[group_col]] == treatment_name)

    # Store results
    comparison_results[[comp_name]] <- list(
      expression_data = filtered_expr,
      sample_info = filtered_sample_info,
      control_name = control_name,
      treatment_name = treatment_name,
      n_control = n_control,
      n_treatment = n_treatment,
      original_groups = list(
        control = control_groups,
        treatment = treatment_groups
      ),
      # Store original group info if needed for reference
      original_group_mapping = data.frame(
        Sample = filtered_sample_info[[sample_col]],
        OriginalGroup = original_group_info,
        MergedGroup = filtered_sample_info[[group_col]],
        stringsAsFactors = FALSE
      )
    )

    # Print summary
    cat("Comparison:", comp_name, "\n")
    if (length(control_groups) > 1) {
      cat("  Control (merged): ", control_name, "\n")
      cat("    - Original groups:", paste(control_groups, collapse = ", "), "\n")
    } else {
      cat("  Control (", control_name, "):", n_control, "samples\n")
    }
    if (length(treatment_groups) > 1) {
      cat("  Treatment (merged): ", treatment_name, "\n")
      cat("    - Original groups:", paste(treatment_groups, collapse = ", "), "\n")
    } else {
      cat("  Treatment (", treatment_name, "):", n_treatment, "samples\n")
    }
    cat("  Control samples:", n_control, "\n")
    cat("  Treatment samples:", n_treatment, "\n")
    cat("  Total samples:", length(valid_samples), "\n")
    cat("  Data dimensions:", nrow(filtered_expr), "proteins ×", ncol(filtered_expr) - (has_id_col && include_id_col), "samples\n\n")
  }

  cat("Generated", length(comparison_results), "comparison groups successfully.\n")

  return(comparison_results)
}

#' Generate all pairwise comparisons between groups
#'
#' @description
#' Automatically generates all possible pairwise comparisons between groups
#'
#' @param expression_data Expression data matrix
#' @param sample_info Sample information data frame
#' @param exclude_groups Groups to exclude from comparisons (optional)
#' @param control_groups Groups to always use as control when present (optional)
#' @param id_col ID column name, default "Accession"
#' @param sample_col Sample column name, default "Sample"
#' @param group_col Group column name, default "Group"
#' @param include_id_col Whether to include ID column in output, default TRUE
#'
#' @return Named list of all pairwise comparison groups
#'
#' @export
create_all_pairwise_comparisons <- function(expression_data,
                                            sample_info,
                                            exclude_groups = NULL,
                                            control_groups = NULL,
                                            id_col = "Accession",
                                            sample_col = "Sample",
                                            group_col = "Group",
                                            include_id_col = TRUE) {
  # Get all unique groups
  all_groups <- unique(sample_info[[group_col]])

  # Remove excluded groups
  if (!is.null(exclude_groups)) {
    all_groups <- setdiff(all_groups, exclude_groups)
  }

  if (length(all_groups) < 2) {
    stop("Need at least 2 groups for pairwise comparisons")
  }

  cat("Generating pairwise comparisons for groups:", paste(all_groups, collapse = ", "), "\n\n")

  # Generate all pairwise combinations
  comparisons <- list()

  for (i in 1:(length(all_groups) - 1)) {
    for (j in (i + 1):length(all_groups)) {
      group1 <- all_groups[i]
      group2 <- all_groups[j]

      # Determine control and treatment
      if (!is.null(control_groups)) {
        if (group1 %in% control_groups && !(group2 %in% control_groups)) {
          control <- group1
          treatment <- group2
        } else if (group2 %in% control_groups && !(group1 %in% control_groups)) {
          control <- group2
          treatment <- group1
        } else {
          # Both or neither are in control_groups, use alphabetical order
          if (group1 < group2) {
            control <- group1
            treatment <- group2
          } else {
            control <- group2
            treatment <- group1
          }
        }
      } else {
        # Use alphabetical order
        if (group1 < group2) {
          control <- group1
          treatment <- group2
        } else {
          control <- group2
          treatment <- group1
        }
      }

      comparisons[[length(comparisons) + 1]] <- list(
        control = control,
        treatment = treatment,
        name = paste0(treatment, "_vs_", control)
      )
    }
  }

  # Use create_comparison_groups to generate the actual comparisons
  return(create_comparison_groups(
    expression_data = expression_data,
    sample_info = sample_info,
    comparisons = comparisons,
    id_col = id_col,
    sample_col = sample_col,
    group_col = group_col,
    include_id_col = include_id_col
  ))
}

#' Create comparison groups with specific control
#'
#' @description
#' Creates comparisons where one or more groups are always the control against all others.
#' Now supports multiple groups as the control.
#'
#' @param expression_data Expression data matrix
#' @param sample_info Sample information data frame
#' @param control_group Name(s) of the control group(s) - can be a vector
#' @param treatment_groups Names of treatment groups (optional, uses all others if NULL)
#' @param merge_control If TRUE and control_group is a vector, merge all control groups
#'   into one. If FALSE, create separate comparisons for each control group.
#' @param id_col ID column name, default "Accession"
#' @param sample_col Sample column name, default "Sample"
#' @param group_col Group column name, default "Group"
#' @param include_id_col Whether to include ID column in output, default TRUE
#'
#' @return Named list of comparison groups
#'
#' @export
#'
#' @examples
#' # Single control vs all
#' create_control_vs_all_comparisons(data, sample_info, control_group = "Healthy")
#'
#' # Multiple controls merged into one
#' create_control_vs_all_comparisons(data, sample_info,
#'   control_group = c("Healthy", "Control2"), merge_control = TRUE
#' )
create_control_vs_all_comparisons <- function(expression_data,
                                              sample_info,
                                              control_group,
                                              treatment_groups = NULL,
                                              merge_control = TRUE,
                                              id_col = "Accession",
                                              sample_col = "Sample",
                                              group_col = "Group",
                                              include_id_col = TRUE) {
  # Get all unique groups
  all_groups <- unique(sample_info[[group_col]])

  # Ensure control_group is a character vector
  control_group <- as.character(control_group)

  # Check if control groups exist
  missing_control <- setdiff(control_group, all_groups)
  if (length(missing_control) > 0) {
    stop(paste("Control group(s) not found in data:", paste(missing_control, collapse = ", ")))
  }

  # Determine treatment groups
  if (is.null(treatment_groups)) {
    treatment_groups <- setdiff(all_groups, control_group)
  } else {
    # Validate treatment groups
    missing_treatments <- setdiff(treatment_groups, all_groups)
    if (length(missing_treatments) > 0) {
      stop(paste("Treatment groups not found:", paste(missing_treatments, collapse = ", ")))
    }
  }

  if (length(treatment_groups) == 0) {
    stop("No treatment groups specified or available")
  }

  # Generate control name for display
  if (length(control_group) == 1) {
    control_name <- control_group
  } else {
    control_name <- paste(control_group, collapse = "+")
  }

  cat(
    "Creating comparisons with", control_name, "as control against:",
    paste(treatment_groups, collapse = ", "), "\n\n"
  )

  # Generate comparisons
  if (merge_control || length(control_group) == 1) {
    # Merge all control groups - each comparison has all controls vs one treatment
    comparisons <- lapply(treatment_groups, function(treat) {
      list(
        control = control_group, # Pass the vector
        treatment = treat,
        name = paste0(treat, "_vs_", control_name)
      )
    })
  } else {
    # Create separate comparisons for each control group
    comparisons <- list()
    for (ctrl in control_group) {
      for (treat in treatment_groups) {
        comparisons[[length(comparisons) + 1]] <- list(
          control = ctrl,
          treatment = treat,
          name = paste0(treat, "_vs_", ctrl)
        )
      }
    }
  }

  # Use create_comparison_groups to generate the actual comparisons
  return(create_comparison_groups(
    expression_data = expression_data,
    sample_info = sample_info,
    comparisons = comparisons,
    id_col = id_col,
    sample_col = sample_col,
    group_col = group_col,
    include_id_col = include_id_col
  ))
}

#' Create one-vs-rest comparisons
#'
#' @description
#' For each group, creates a comparison where that group is the treatment
#' and all other groups are merged as control.
#'
#' @param expression_data Expression data matrix
#' @param sample_info Sample information data frame
#' @param groups Groups to include (optional, uses all if NULL)
#' @param id_col ID column name, default "Accession"
#' @param sample_col Sample column name, default "Sample"
#' @param group_col Group column name, default "Group"
#' @param include_id_col Whether to include ID column in output, default TRUE
#'
#' @return Named list of comparison groups
#'
#' @export
#'
#' @examples
#' # Each group vs all others
#' one_vs_rest <- create_one_vs_rest_comparisons(data, sample_info)
create_one_vs_rest_comparisons <- function(expression_data,
                                           sample_info,
                                           groups = NULL,
                                           id_col = "Accession",
                                           sample_col = "Sample",
                                           group_col = "Group",
                                           include_id_col = TRUE) {
  # Get all unique groups
  all_groups <- unique(sample_info[[group_col]])

  # Determine which groups to use
  if (is.null(groups)) {
    groups <- all_groups
  } else {
    missing_groups <- setdiff(groups, all_groups)
    if (length(missing_groups) > 0) {
      stop(paste("Groups not found:", paste(missing_groups, collapse = ", ")))
    }
  }

  if (length(groups) < 2) {
    stop("Need at least 2 groups for one-vs-rest comparisons")
  }

  cat("Creating one-vs-rest comparisons for groups:", paste(groups, collapse = ", "), "\n\n")

  # Generate comparisons
  comparisons <- lapply(groups, function(treat) {
    rest <- setdiff(groups, treat)
    list(
      control = rest, # All other groups as control
      treatment = treat,
      name = paste0(treat, "_vs_Rest")
    )
  })

  # Use create_comparison_groups to generate the actual comparisons
  return(create_comparison_groups(
    expression_data = expression_data,
    sample_info = sample_info,
    comparisons = comparisons,
    id_col = id_col,
    sample_col = sample_col,
    group_col = group_col,
    include_id_col = include_id_col
  ))
}

#' Print summary of comparison groups
#'
#' @description
#' Prints a summary table of all comparison groups
#'
#' @param comparison_groups List of comparison groups (output from create_comparison_groups)
#'
#' @export
print_comparison_summary <- function(comparison_groups) {
  if (length(comparison_groups) == 0) {
    cat("No comparison groups found.\n")
    return(invisible())
  }

  # Create summary data frame
  summary_df <- data.frame(
    Comparison = names(comparison_groups),
    Control = sapply(comparison_groups, function(x) x$control_name),
    Treatment = sapply(comparison_groups, function(x) x$treatment_name),
    N_Control = sapply(comparison_groups, function(x) x$n_control),
    N_Treatment = sapply(comparison_groups, function(x) x$n_treatment),
    Total_Samples = sapply(comparison_groups, function(x) x$n_control + x$n_treatment),
    N_Proteins = sapply(comparison_groups, function(x) nrow(x$expression_data)),
    Control_Groups = sapply(comparison_groups, function(x) paste(x$original_groups$control, collapse = ", ")),
    Treatment_Groups = sapply(comparison_groups, function(x) paste(x$original_groups$treatment, collapse = ", ")),
    stringsAsFactors = FALSE
  )

  cat("=== Comparison Groups Summary ===\n\n")
  print(summary_df[, 1:7]) # Print main columns

  # Check if any comparison has merged groups
  has_merged <- any(sapply(comparison_groups, function(x) {
    length(x$original_groups$control) > 1 || length(x$original_groups$treatment) > 1
  }))

  if (has_merged) {
    cat("\n=== Merged Groups Detail ===\n")
    for (name in names(comparison_groups)) {
      comp <- comparison_groups[[name]]
      if (length(comp$original_groups$control) > 1 || length(comp$original_groups$treatment) > 1) {
        cat("\n", name, ":\n", sep = "")
        if (length(comp$original_groups$control) > 1) {
          cat("  Control groups:", paste(comp$original_groups$control, collapse = ", "), "\n")
        }
        if (length(comp$original_groups$treatment) > 1) {
          cat("  Treatment groups:", paste(comp$original_groups$treatment, collapse = ", "), "\n")
        }
      }
    }
  }

  cat("\nTotal comparisons:", nrow(summary_df), "\n")

  return(invisible(summary_df))
}