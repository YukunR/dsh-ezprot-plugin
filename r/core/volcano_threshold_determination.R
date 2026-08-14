# ==============================================================================
# VOLCANO THRESHOLD DETERMINATION UTILITIES
# ==============================================================================
# Functions for determining and managing FC and P-value thresholds
# in differential expression analysis
#
# Usage: source("core/volcano_threshold_determination.R")
# ==============================================================================

library(dplyr)

# ===========================
# ==== Preview Functions ====
# ===========================

#' Preview regulated protein counts at different thresholds
#'
#' @param ttest_results Results from t-test analysis
#' @param fc_column Name of log2 fold change column
#' @param fc_thresholds Vector of FC thresholds to preview
#' @param p_thresholds Vector of P-value thresholds to preview
#' @param fixed_p P-value to use when previewing FC thresholds
#' @param fixed_fc FC to use when previewing P-value thresholds
#'
#' @return List with fc_preview and p_preview data frames
#' @export
preview_thresholds <- function(ttest_results,
                               fc_column = "log2_fold_change",
                               fc_thresholds = c(1.3, 1.5, 2.0, 3.0),
                               p_thresholds = c(0.001, 0.01, 0.05, 0.1),
                               fixed_p = 0.05,
                               fixed_fc = 2) {
  fc_values <- ttest_results[[fc_column]]
  p_values <- ttest_results$p_value
  total_proteins <- nrow(ttest_results)

  # Preview FC thresholds (at fixed p)
  fc_preview <- data.frame(
    FC_Threshold = fc_thresholds,
    Log2_FC = round(log2(fc_thresholds), 3),
    P_Threshold = fixed_p,
    Up = NA_integer_,
    Down = NA_integer_,
    No_Change = NA_integer_,
    Selected = "",
    stringsAsFactors = FALSE
  )

  for (i in seq_along(fc_thresholds)) {
    log2_thresh <- log2(fc_thresholds[i])
    up_count <- sum(fc_values >= log2_thresh & p_values <= fixed_p, na.rm = TRUE)
    down_count <- sum(fc_values <= -log2_thresh & p_values <= fixed_p, na.rm = TRUE)
    fc_preview$Up[i] <- up_count
    fc_preview$Down[i] <- down_count
    fc_preview$No_Change[i] <- total_proteins - up_count - down_count
  }

  # Preview P thresholds (at fixed FC)
  p_preview <- data.frame(
    P_Threshold = p_thresholds,
    FC_Threshold = fixed_fc,
    Log2_FC = round(log2(fixed_fc), 3),
    Up = NA_integer_,
    Down = NA_integer_,
    No_Change = NA_integer_,
    Selected = "",
    stringsAsFactors = FALSE
  )

  log2_fc_fixed <- log2(fixed_fc)
  for (i in seq_along(p_thresholds)) {
    up_count <- sum(fc_values >= log2_fc_fixed & p_values <= p_thresholds[i], na.rm = TRUE)
    down_count <- sum(fc_values <= -log2_fc_fixed & p_values <= p_thresholds[i], na.rm = TRUE)
    p_preview$Up[i] <- up_count
    p_preview$Down[i] <- down_count
    p_preview$No_Change[i] <- total_proteins - up_count - down_count
  }

  return(list(fc_preview = fc_preview, p_preview = p_preview, total = total_proteins))
}

#' Count proteins at specific thresholds
#'
#' @param ttest_results Results from t-test analysis
#' @param fc_threshold FC threshold (linear scale)
#' @param p_threshold P-value threshold
#' @param fc_column Name of log2 fold change column
#'
#' @return Named vector with up, down, no_change, and total counts
#' @export
count_regulated_proteins <- function(ttest_results,
                                     fc_threshold,
                                     p_threshold,
                                     fc_column = "log2_fold_change") {
  fc_values <- ttest_results[[fc_column]]
  p_values <- ttest_results$p_value
  total_proteins <- nrow(ttest_results)

  log2_thresh <- log2(fc_threshold)
  up_count <- sum(fc_values >= log2_thresh & p_values <= p_threshold, na.rm = TRUE)
  down_count <- sum(fc_values <= -log2_thresh & p_values <= p_threshold, na.rm = TRUE)
  no_change <- total_proteins - up_count - down_count

  return(c(up = up_count, down = down_count, no_change = no_change, total = total_proteins))
}

#' Add user selection to preview table and display
#'
#' @param preview_df Preview data frame (fc_preview or p_preview)
#' @param fc_threshold Selected FC threshold
#' @param p_threshold Selected P-value threshold
#' @param ttest_results T-test results for counting
#' @param fc_column Name of log2 fold change column
#' @param preview_type "fc" or "p" indicating which preview table
#'
#' @return Updated preview data frame with selection marked
add_selection_to_preview <- function(preview_df,
                                     fc_threshold,
                                     p_threshold,
                                     ttest_results,
                                     fc_column = "log2_fold_change",
                                     preview_type = "fc") {
  total_proteins <- nrow(ttest_results)

  # Clear previous selection markers
  preview_df$Selected <- ""

  # Count proteins at selected thresholds
  counts <- count_regulated_proteins(ttest_results, fc_threshold, p_threshold, fc_column)

  if (preview_type == "fc") {
    # Check if FC threshold already exists in preview
    # Use tolerance for floating point comparison
    match_idx <- which(abs(preview_df$FC_Threshold - fc_threshold) < 1e-6 &
      abs(preview_df$P_Threshold - p_threshold) < 1e-6)

    if (length(match_idx) > 0) {
      # Mark existing row
      preview_df$Selected[match_idx[1]] <- "<-"
    } else {
      # Add new row
      new_row <- data.frame(
        FC_Threshold = fc_threshold,
        Log2_FC = round(log2(fc_threshold), 3),
        P_Threshold = p_threshold,
        Up = counts["up"],
        Down = counts["down"],
        No_Change = counts["no_change"],
        Selected = "<-",
        stringsAsFactors = FALSE
      )
      preview_df <- rbind(preview_df, new_row)
      # Sort by FC_Threshold
      preview_df <- preview_df[order(preview_df$FC_Threshold), ]
    }
  } else {
    # P-value preview
    match_idx <- which(abs(preview_df$P_Threshold - p_threshold) < 1e-6 &
      abs(preview_df$FC_Threshold - fc_threshold) < 1e-6)

    if (length(match_idx) > 0) {
      preview_df$Selected[match_idx[1]] <- "<-"
    } else {
      new_row <- data.frame(
        P_Threshold = p_threshold,
        FC_Threshold = fc_threshold,
        Log2_FC = round(log2(fc_threshold), 3),
        Up = counts["up"],
        Down = counts["down"],
        No_Change = counts["no_change"],
        Selected = "<-",
        stringsAsFactors = FALSE
      )
      preview_df <- rbind(preview_df, new_row)
      preview_df <- preview_df[order(preview_df$P_Threshold), ]
    }
  }

  rownames(preview_df) <- NULL
  return(preview_df)
}

#' Print preview table with nice formatting
#'
#' @param preview_df Preview data frame
#' @param title Table title
print_preview_table <- function(preview_df, title = NULL) {
  if (!is.null(title)) {
    cat(title, "\n\n")
  }
  print(preview_df, row.names = FALSE)
  cat("\n")
}

# =====================================
# ==== Interactive Threshold Input ====
# =====================================

#' Get thresholds interactively from user
#'
#' @param ttest_results Results from t-test analysis
#' @param group_name Name of the comparison group
#' @param need_fc Whether FC threshold is needed
#' @param need_p Whether P-value threshold is needed
#' @param default_fc Default FC threshold for preview
#' @param default_p Default P-value threshold for preview
#' @param fc_column Name of log2 fold change column
#'
#' @return List with fc_threshold and p_threshold
#' @export
get_thresholds_interactive <- function(ttest_results,
                                       group_name,
                                       need_fc = TRUE,
                                       need_p = TRUE,
                                       default_fc = 1.5,
                                       default_p = 0.05,
                                       fc_column = "log2_fold_change") {
  cat("\n")
  cat("================================================================\n")
  cat("Threshold Selection for:", group_name, "\n")
  cat("================================================================\n\n")

  # Initialize with default values
  fc_threshold <- default_fc
  p_threshold <- default_p

  # Get initial preview tables
  preview <- preview_thresholds(ttest_results, fc_column,
    fixed_p = default_p, fixed_fc = default_fc
  )
  fc_preview <- preview$fc_preview
  p_preview <- preview$p_preview

  # Mark default values in preview and show
  updated_preview <- add_selection_to_preview(
    fc_preview, fc_threshold, p_threshold, ttest_results, fc_column, "fc"
  )
  cat(
    "Default thresholds: FC =", default_fc, "(log2 =", round(log2(default_fc), 3),
    "), P =", default_p, "\n\n"
  )
  print_preview_table(updated_preview, "Protein counts at different FC thresholds:")

  if (need_p) {
    print_preview_table(
      p_preview,
      paste0("Preview of protein counts at different P-value thresholds (FC = ", default_fc, "):")
    )
  }

  # Ask user if default is OK
  cat("Accept default thresholds? (y/n/fc/p):\n")
  cat("  y  = accept defaults and continue\n")
  cat("  n  = enter new thresholds\n")
  if (need_fc) cat("  fc = change FC threshold only\n")
  if (need_p) cat("  p  = change P-value threshold only\n")

  initial_response <- tolower(readline("Your choice: "))

  if (initial_response %in% c("y", "yes", "")) {
    # Accept defaults, go to final confirmation
    confirmed <- TRUE
  } else {
    confirmed <- FALSE

    if (initial_response %in% c("n", "no")) {
      # Enter both thresholds
      if (need_fc) {
        valid_input <- FALSE
        while (!valid_input) {
          cat("\nEnter FC threshold (e.g., 1.5, 2.0): ")
          user_input <- readline()

          if (user_input == "") {
            valid_input <- TRUE
          } else {
            new_fc <- suppressWarnings(as.numeric(user_input))
            if (is.na(new_fc)) {
              cat("Invalid input. Please enter a numeric value.\n")
            } else if (new_fc <= 1) {
              cat("FC threshold must be greater than 1. Please try again.\n")
            } else {
              fc_threshold <- new_fc
              valid_input <- TRUE
            }
          }
        }
      }

      if (need_p) {
        valid_input <- FALSE
        while (!valid_input) {
          cat("Enter P-value threshold (e.g., 0.05, 0.01): ")
          user_input <- readline()

          if (user_input == "") {
            valid_input <- TRUE
          } else {
            new_p <- suppressWarnings(as.numeric(user_input))
            if (is.na(new_p)) {
              cat("Invalid input. Please enter a numeric value.\n")
            } else if (new_p <= 0 || new_p >= 1) {
              cat("P-value threshold must be between 0 and 1. Please try again.\n")
            } else {
              p_threshold <- new_p
              valid_input <- TRUE
            }
          }
        }
      }
    } else if (initial_response == "fc" && need_fc) {
      valid_input <- FALSE
      while (!valid_input) {
        cat("\nEnter FC threshold (e.g., 1.5, 2.0): ")
        user_input <- readline()

        if (user_input == "") {
          valid_input <- TRUE
        } else {
          new_fc <- suppressWarnings(as.numeric(user_input))
          if (is.na(new_fc)) {
            cat("Invalid input. Please enter a numeric value.\n")
          } else if (new_fc <= 1) {
            cat("FC threshold must be greater than 1. Please try again.\n")
          } else {
            fc_threshold <- new_fc
            valid_input <- TRUE
          }
        }
      }
    } else if (initial_response == "p" && need_p) {
      valid_input <- FALSE
      while (!valid_input) {
        cat("\nEnter P-value threshold (e.g., 0.05, 0.01): ")
        user_input <- readline()

        if (user_input == "") {
          valid_input <- TRUE
        } else {
          new_p <- suppressWarnings(as.numeric(user_input))
          if (is.na(new_p)) {
            cat("Invalid input. Please enter a numeric value.\n")
          } else if (new_p <= 0 || new_p >= 1) {
            cat("P-value threshold must be between 0 and 1. Please try again.\n")
          } else {
            p_threshold <- new_p
            valid_input <- TRUE
          }
        }
      }
    } else {
      cat("Invalid choice.\n")
    }
  }

  # Confirmation loop
  while (!confirmed) {
    # Update preview table with current selection
    updated_preview <- add_selection_to_preview(
      fc_preview, fc_threshold, p_threshold, ttest_results, fc_column, "fc"
    )

    cat("\n")
    cat("----------------------------------------------------------------\n")
    cat(
      "Current selection: FC =", fc_threshold, "(log2 =", round(log2(fc_threshold), 3),
      "), P =", p_threshold, "\n"
    )
    cat("----------------------------------------------------------------\n\n")

    print_preview_table(updated_preview, "Protein counts comparison:")

    cat("Confirm these thresholds? (y/n/fc/p):\n")
    cat("  y  = confirm and continue\n")
    cat("  n  = re-enter both thresholds\n")
    cat("  fc = change FC threshold only\n")
    cat("  p  = change P-value threshold only\n")
    response <- tolower(readline("Your choice: "))

    if (response %in% c("y", "yes", "")) {
      confirmed <- TRUE
    } else if (response %in% c("n", "no")) {
      # Re-enter both
      cat("\n--- Re-entering thresholds ---\n\n")

      # Show preview again
      print_preview_table(
        fc_preview,
        paste0(
          "Preview of protein counts at different FC thresholds (P-value = ",
          default_p, "):"
        )
      )

      valid_input <- FALSE
      while (!valid_input) {
        cat("Enter FC threshold [current:", fc_threshold, "]: ")
        user_input <- readline()
        if (user_input == "") {
          valid_input <- TRUE
        } else {
          new_fc <- suppressWarnings(as.numeric(user_input))
          if (!is.na(new_fc) && new_fc > 1) {
            fc_threshold <- new_fc
            valid_input <- TRUE
          } else {
            cat("Invalid. FC must be > 1.\n")
          }
        }
      }

      valid_input <- FALSE
      while (!valid_input) {
        cat("Enter P-value threshold [current:", p_threshold, "]: ")
        user_input <- readline()
        if (user_input == "") {
          valid_input <- TRUE
        } else {
          new_p <- suppressWarnings(as.numeric(user_input))
          if (!is.na(new_p) && new_p > 0 && new_p < 1) {
            p_threshold <- new_p
            valid_input <- TRUE
          } else {
            cat("Invalid. P must be between 0 and 1.\n")
          }
        }
      }
    } else if (response == "fc") {
      cat("\n")
      # Show current preview with selection
      print_preview_table(updated_preview, "Current protein counts:")

      valid_input <- FALSE
      while (!valid_input) {
        cat("Enter new FC threshold [current:", fc_threshold, "]: ")
        user_input <- readline()
        if (user_input == "") {
          valid_input <- TRUE
        } else {
          new_fc <- suppressWarnings(as.numeric(user_input))
          if (!is.na(new_fc) && new_fc > 1) {
            fc_threshold <- new_fc
            valid_input <- TRUE
          } else {
            cat("Invalid. FC must be > 1.\n")
          }
        }
      }
    } else if (response == "p") {
      cat("\n")
      # Show P-value preview
      print_preview_table(
        p_preview,
        paste0(
          "Preview of protein counts at different P-value thresholds (FC = ",
          default_fc, "):"
        )
      )

      valid_input <- FALSE
      while (!valid_input) {
        cat("Enter new P-value threshold [current:", p_threshold, "]: ")
        user_input <- readline()
        if (user_input == "") {
          valid_input <- TRUE
        } else {
          new_p <- suppressWarnings(as.numeric(user_input))
          if (!is.na(new_p) && new_p > 0 && new_p < 1) {
            p_threshold <- new_p
            valid_input <- TRUE
          } else {
            cat("Invalid. P must be between 0 and 1.\n")
          }
        }
      }
    } else {
      cat("Invalid choice. Please enter y, n, fc, or p.\n")
    }
  }

  # Final summary
  counts <- count_regulated_proteins(ttest_results, fc_threshold, p_threshold, fc_column)
  cat("\n")
  cat("================================================================\n")
  cat("Final selection:\n")
  cat("  FC threshold:", fc_threshold, "(log2 =", round(log2(fc_threshold), 3), ")\n")
  cat("  P-value threshold:", p_threshold, "\n")
  cat("  Up-regulated:", counts["up"], "\n")
  cat("  Down-regulated:", counts["down"], "\n")
  cat("  No change:", counts["no_change"], "\n")
  cat("================================================================\n\n")

  return(list(fc_threshold = fc_threshold, p_threshold = p_threshold))
}

# ===============================================
# ==== Main Threshold Determination Function ====
# ===============================================

#' Determine FC and P-value thresholds based on configuration
#'
#' @param ttest_results Results from t-test analysis
#' @param group_name Name of the comparison group
#' @param config Configuration list from get_config()
#' @param comparison_config Configuration for this specific comparison (from config$comparisons)
#' @param fc_coverage_result Result from analyze_coverage() function (optional, for auto mode)
#' @param fc_column Name of log2 fold change column
#' @param output_dir Output directory for saving threshold info
#'
#' @return List with fc_threshold, p_threshold, and metadata
#' @export
determine_thresholds <- function(ttest_results,
                                 group_name,
                                 config,
                                 comparison_config = NULL,
                                 fc_coverage_result = NULL,
                                 fc_column = "log2_fold_change",
                                 output_dir = NULL) {
  fc_threshold_mode <- config$fc_threshold_mode
  p_threshold_mode <- config$p_threshold_mode

  fc_threshold <- NULL
  p_threshold <- NULL
  fc_source <- NULL
  p_source <- NULL

  # ---- Determine P-value threshold ----
  if (p_threshold_mode == "global") {
    p_threshold <- config$global_p_threshold
    p_source <- "global"
    cat("P-value threshold mode: global (", p_threshold, ")\n")
  } else if (p_threshold_mode == "per_comparison") {
    if (!is.null(comparison_config) && !is.null(comparison_config$p_threshold)) {
      p_threshold <- comparison_config$p_threshold
      p_source <- "comparison_config"
      cat("P-value threshold: from comparison config (", p_threshold, ")\n")
    } else {
      p_threshold <- NULL
      p_source <- "interactive"
      cat("P-value threshold: will be set interactively\n")
    }
  } else {
    stop(paste("Invalid p_threshold_mode:", p_threshold_mode))
  }

  # ---- Determine FC threshold ----
  if (fc_threshold_mode == "auto") {
    cat("FC threshold mode: auto (using coverage analysis)\n")

    # Check for ignored settings and warn
    if (!is.null(config$global_fc_threshold) && config$global_fc_threshold != 1.5) {
      warning(
        "fc_threshold_mode is 'auto': global_fc_threshold (",
        config$global_fc_threshold, ") will be IGNORED"
      )
    }
    if (!is.null(comparison_config) && !is.null(comparison_config$fc_threshold)) {
      warning(
        "fc_threshold_mode is 'auto': fc_threshold in comparison '",
        group_name, "' (", comparison_config$fc_threshold, ") will be IGNORED"
      )
    }

    # Use coverage result
    if (is.null(fc_coverage_result)) {
      stop("fc_coverage_result is required when fc_threshold_mode is 'auto'")
    }
    fc_threshold <- fc_coverage_result$threshold
    fc_source <- "auto_coverage"
    cat("Auto-calculated FC threshold:", fc_threshold, "\n")

    # If p_threshold not set yet, use global default
    if (is.null(p_threshold)) {
      p_threshold <- config$global_p_threshold
      p_source <- "global_default"
    }
  } else if (fc_threshold_mode == "global") {
    fc_threshold <- config$global_fc_threshold
    fc_source <- "global"
    cat("FC threshold mode: global (", fc_threshold, ")\n")

    # If p_threshold not set yet, use global default
    if (is.null(p_threshold)) {
      p_threshold <- config$global_p_threshold
      p_source <- "global_default"
    }
  } else if (fc_threshold_mode == "per_comparison") {
    cat("FC threshold mode: per_comparison\n")

    if (!is.null(comparison_config) && !is.null(comparison_config$fc_threshold)) {
      fc_threshold <- comparison_config$fc_threshold
      fc_source <- "comparison_config"
      cat("FC threshold: from comparison config (", fc_threshold, ")\n")

      # If p_threshold not set, use global default
      if (is.null(p_threshold)) {
        p_threshold <- config$global_p_threshold
        p_source <- "global_default"
      }
    } else {
      fc_threshold <- NULL
      fc_source <- "interactive"
      cat("FC threshold: will be set interactively\n")
    }
  } else {
    stop(paste("Invalid fc_threshold_mode:", fc_threshold_mode))
  }

  # ---- Interactive threshold input if needed ----
  need_fc_input <- is.null(fc_threshold)
  need_p_input <- is.null(p_threshold)

  if (need_fc_input || need_p_input) {
    # Determine default FC for interactive mode
    default_fc <- if (!is.null(fc_coverage_result)) fc_coverage_result$threshold else 1.5
    default_p <- config$global_p_threshold

    thresholds <- get_thresholds_interactive(
      ttest_results = ttest_results,
      group_name = group_name,
      need_fc = need_fc_input,
      need_p = need_p_input,
      default_fc = default_fc,
      default_p = default_p,
      fc_column = fc_column
    )

    if (need_fc_input) {
      fc_threshold <- thresholds$fc_threshold
      fc_source <- "interactive"
    }
    if (need_p_input) {
      p_threshold <- thresholds$p_threshold
      p_source <- "interactive"
    }
  }

  # Print final thresholds (only if not from interactive, which already prints)
  if (!need_fc_input && !need_p_input) {
    cat("\n--- Final Thresholds ---\n")
    cat("FC threshold:", fc_threshold, "(log2 =", round(log2(fc_threshold), 3), ")\n")
    cat("P-value threshold:", p_threshold, "\n")
    cat("------------------------\n\n")
  }

  # Create result object
  result <- list(
    fc_threshold = fc_threshold,
    p_threshold = p_threshold,
    fc_source = fc_source,
    p_source = p_source,
    fc_threshold_mode = fc_threshold_mode,
    p_threshold_mode = p_threshold_mode,
    log2_fc_threshold = log2(fc_threshold)
  )

  # Save threshold info if output_dir provided
  if (!is.null(output_dir)) {
    threshold_info <- data.frame(
      group_name = group_name,
      fc_threshold_mode = fc_threshold_mode,
      p_threshold_mode = p_threshold_mode,
      fc_threshold = fc_threshold,
      log2_fc_threshold = log2(fc_threshold),
      fc_source = fc_source,
      p_threshold = p_threshold,
      p_source = p_source,
      timestamp = Sys.time(),
      stringsAsFactors = FALSE
    )

    if (!dir.exists(output_dir)) {
      dir.create(output_dir, recursive = TRUE)
    }
    write.csv(threshold_info,
      file = file.path(output_dir, "threshold_info.csv"),
      row.names = FALSE
    )
  }

  return(result)
}

# =================================================
# ==== Helper Functions for Setting Thresholds ====
# =================================================

#' Set FC threshold for a specific comparison
#'
#' @param comparison_name Name of the comparison to modify
#' @param fc_threshold FC threshold value to set
#' @export
set_comparison_fc_threshold <- function(comparison_name, fc_threshold) {
  if (!exists("comparisons", envir = .GlobalEnv)) {
    stop("No comparisons defined in global environment")
  }
  comparisons <- get("comparisons", envir = .GlobalEnv)
  found <- FALSE
  for (i in seq_along(comparisons)) {
    if (comparisons[[i]]$name == comparison_name) {
      comparisons[[i]]$fc_threshold <- fc_threshold
      found <- TRUE
      break
    }
  }
  if (!found) stop(paste("Comparison", comparison_name, "not found"))
  assign("comparisons", comparisons, envir = .GlobalEnv)
  cat("Set FC threshold for", comparison_name, "to", fc_threshold, "\n")
}

#' Set P-value threshold for a specific comparison
#'
#' @param comparison_name Name of the comparison to modify
#' @param p_threshold P-value threshold to set
#' @export
set_comparison_p_threshold <- function(comparison_name, p_threshold) {
  if (!exists("comparisons", envir = .GlobalEnv)) {
    stop("No comparisons defined in global environment")
  }
  comparisons <- get("comparisons", envir = .GlobalEnv)
  found <- FALSE
  for (i in seq_along(comparisons)) {
    if (comparisons[[i]]$name == comparison_name) {
      comparisons[[i]]$p_threshold <- p_threshold
      found <- TRUE
      break
    }
  }
  if (!found) stop(paste("Comparison", comparison_name, "not found"))
  assign("comparisons", comparisons, envir = .GlobalEnv)
  cat("Set P-value threshold for", comparison_name, "to", p_threshold, "\n")
}

#' Set thresholds for all comparisons
#'
#' @param fc_threshold FC threshold value (optional)
#' @param p_threshold P-value threshold value (optional)
#' @export
set_all_thresholds <- function(fc_threshold = NULL, p_threshold = NULL) {
  if (!exists("comparisons", envir = .GlobalEnv)) {
    stop("No comparisons defined in global environment")
  }
  comparisons <- get("comparisons", envir = .GlobalEnv)
  for (i in seq_along(comparisons)) {
    if (!is.null(fc_threshold)) comparisons[[i]]$fc_threshold <- fc_threshold
    if (!is.null(p_threshold)) comparisons[[i]]$p_threshold <- p_threshold
  }
  assign("comparisons", comparisons, envir = .GlobalEnv)
  msg_parts <- c()
  if (!is.null(fc_threshold)) msg_parts <- c(msg_parts, paste("FC =", fc_threshold))
  if (!is.null(p_threshold)) msg_parts <- c(msg_parts, paste("P =", p_threshold))
  cat("Set", paste(msg_parts, collapse = ", "), "for all", length(comparisons), "comparisons\n")
}

#' Clear all thresholds from comparisons
#'
#' @export
clear_all_thresholds <- function() {
  if (!exists("comparisons", envir = .GlobalEnv)) {
    stop("No comparisons defined in global environment")
  }
  comparisons <- get("comparisons", envir = .GlobalEnv)
  for (i in seq_along(comparisons)) {
    comparisons[[i]]$fc_threshold <- NULL
    comparisons[[i]]$p_threshold <- NULL
  }
  assign("comparisons", comparisons, envir = .GlobalEnv)
  cat("Cleared all thresholds from", length(comparisons), "comparisons\n")
}