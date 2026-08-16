# ===============================================
# ==== Checkpoint System for R Data Analysis ====
# ===============================================
# A robust checkpoint system that allows resuming analysis from interruption points
# with automatic file integrity checking and error recovery

library(jsonlite)
library(digest)

# Create workspace manager
create_workspace <- function(project_name, base_dir = "./res/") {
  workspace <- list(
    project_name = project_name,
    base_dir = base_dir,
    checkpoint_file = file.path(base_dir, "checkpoint.json"),
    log_file = file.path(base_dir, "analysis.log")
  )

  # Create base directory
  if (!dir.exists(base_dir)) {
    dir.create(base_dir, recursive = TRUE)
    cat("Created directory:", base_dir, "\n")
  }

  return(workspace)
}

# Load checkpoint status
# reset_interrupted = FALSE: do not clear an in-flight current_step. Callers
# that reload DURING step execution (execute_step's success path) pass FALSE
# because current_step is the step being finished, not a previous-session
# interruption; everything else (startup, error/interrupt handlers) keeps the
# default so a stale current_step from a crashed session is cleaned up.
load_checkpoint <- function(workspace, reset_interrupted = TRUE) {
  if (file.exists(workspace$checkpoint_file)) {
    checkpoint <- fromJSON(workspace$checkpoint_file, simplifyDataFrame = FALSE)

    # Handle potential interrupted state from previous session
    if (reset_interrupted && !is.null(checkpoint$current_step)) {
      log_message(
        workspace,
        paste(
          "Detected interrupted step from previous session:", checkpoint$current_step
        ), "WARN"
      )
      log_message(workspace, "This step will be restarted", "INFO")

      # Remove interrupted step from completed steps to ensure it runs again
      checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, checkpoint$current_step)
      checkpoint$current_step <- NULL
      checkpoint$step_start_time <- NULL

      # Save the cleaned state
      write(toJSON(checkpoint, pretty = TRUE, auto_unbox = TRUE), workspace$checkpoint_file)
    }

    # Ensure required fields exist
    if (is.null(checkpoint$config_hashes)) {
      checkpoint$config_hashes <- list()
    }
    if (is.null(checkpoint$config_details)) {
      checkpoint$config_details <- list()
    }
    if (is.null(checkpoint$step_dependencies)) {
      checkpoint$step_dependencies <- list()
    }

    return(checkpoint)
  } else {
    return(list(
      completed_steps = character(0),
      current_step = NULL,
      last_update = Sys.time(),
      file_hashes = list(),
      config_hashes = list(),
      config_details = list(),
      step_dependencies = list(), # Store dependencies for each step
      comparison_groups_completed = character(0),
      step_start_time = NULL
    ))
  }
}

# Save checkpoint status
save_checkpoint <- function(workspace, checkpoint) {
  checkpoint$last_update <- Sys.time()
  write(toJSON(checkpoint, pretty = TRUE, auto_unbox = TRUE), workspace$checkpoint_file)
}

# Log messages with timestamp
log_message <- function(workspace, message, level = "INFO") {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  log_entry <- sprintf("[%s] %s: %s", timestamp, level, message)
  cat(log_entry, "\n")
  write(log_entry, workspace$log_file, append = TRUE)
}

# Calculate file hash for integrity checking
calculate_file_hash <- function(filepath) {
  if (file.exists(filepath)) {
    return(digest(filepath, algo = "md5", file = TRUE))
  }
  return(NULL)
}

# Calculate hash for any R object (for config change detection)
calculate_object_hash <- function(obj) {
  return(digest(obj, algo = "md5"))
}

# Verify file integrity
verify_file_integrity <- function(filepath, expected_hash = NULL) {
  if (!file.exists(filepath)) {
    return(FALSE)
  }

  if (!is.null(expected_hash)) {
    current_hash <- calculate_file_hash(filepath)
    return(current_hash == expected_hash)
  }

  # Basic check: file size > 0
  return(file.size(filepath) > 0)
}

# Clean up step-related files
cleanup_step_files <- function(workspace, step_name, file_patterns = NULL) {
  log_message(workspace, paste("Cleaning files for step:", step_name))

  if (!is.null(file_patterns)) {
    for (pattern in file_patterns) {
      files_to_remove <- list.files(
        workspace$base_dir,
        pattern = pattern, recursive = TRUE, full.names = TRUE
      )
      for (file in files_to_remove) {
        if (file.exists(file)) {
          file.remove(file)
          log_message(workspace, paste("Removed file:", basename(file)))
        }
      }
    }
  }
}

# Helper: define value equality
values_equal <- function(a, b) {
  # Both NULL
  if (is.null(a) && is.null(b)) {
    return(TRUE)
  }
  # One is NULL, the other is not
  if (is.null(a) || is.null(b)) {
    return(FALSE)
  }
  # Both numeric (integer / double)
  if (is.numeric(a) && is.numeric(b)) {
    return(isTRUE(all.equal(a, b, tolerance = 1e-8)))
  }
  # Both data frames
  if (is.data.frame(a) && is.data.frame(b)) {
    return(isTRUE(all.equal(a, b, tolerance = 1e-8)))
  }
  # Both lists (including generic lists)
  if (is.list(a) && is.list(b)) {
    # Different length
    if (length(a) != length(b)) {
      return(FALSE)
    }
    # Different names (if names are present)
    if (!identical(names(a), names(b))) {
      return(FALSE)
    }
    # Compare each element recursively
    for (i in seq_along(a)) {
      if (!values_equal(a[[i]], b[[i]])) {
        return(FALSE)
      }
    }
    return(TRUE)
  }
  # Fallback: strict comparison
  identical(a, b)
}

# Compare two config objects and report differences
compare_configs <- function(old_config, new_config) {
  differences <- list()

  # Get all keys from both configs
  all_keys <- unique(c(names(old_config), names(new_config)))

  for (key in all_keys) {
    old_val <- old_config[[key]]
    new_val <- new_config[[key]]

    # Handle NULL values
    if (is.null(old_val) && is.null(new_val)) {
      next
    } else if (is.null(old_val)) {
      differences[[key]] <- list(old = "NULL", new = new_val)
    } else if (is.null(new_val)) {
      differences[[key]] <- list(old = old_val, new = "NULL")
    } else if (!values_equal(old_val, new_val)) {
      differences[[key]] <- list(old = old_val, new = new_val)
    }
  }

  return(differences)
}

# Format config differences for display
format_config_differences <- function(differences) {
  if (length(differences) == 0) {
    return("No differences")
  }

  lines <- c()
  for (key in names(differences)) {
    old_val <- differences[[key]]$old
    new_val <- differences[[key]]$new

    # Format values for display
    format_value <- function(val) {
      if (is.list(val)) {
        paste(names(val), "=", unlist(val), collapse = ", ")
      } else if (length(val) > 1) {
        paste(val, collapse = ", ")
      } else {
        as.character(val)
      }
    }

    old_str <- format_value(old_val)
    new_str <- format_value(new_val)

    lines <- c(lines, sprintf("  - %s: %s -> %s", key, old_str, new_str))
  }

  return(paste(lines, collapse = "\n"))
}

# Check if configuration has changed for a step (with detailed reporting)
check_config_changed <- function(workspace, step_name, config_value, verbose = TRUE) {
  checkpoint <- load_checkpoint(workspace)
  current_hash <- calculate_object_hash(config_value)
  stored_hash <- checkpoint$config_hashes[[step_name]]
  stored_config <- checkpoint$config_details[[step_name]]

  if (is.null(stored_hash)) {
    return(list(changed = TRUE, reason = "No previous configuration found"))
  }

  if (current_hash != stored_hash) {
    # Find what changed

    differences <- compare_configs(stored_config, config_value)
    diff_text <- format_config_differences(differences)

    if (verbose) {
      cat("\n")
      cat("================================================================\n")
      cat("Configuration changed for step:", step_name, "\n")
      cat("================================================================\n")
      cat("Changes detected:\n")
      cat(diff_text, "\n")
      cat("================================================================\n")
      cat("This step will be re-executed.\n\n")
    }

    return(list(changed = TRUE, reason = "Configuration changed", differences = differences))
  }

  return(list(changed = FALSE))
}

# Find all steps that depend on a given step (using stored dependencies)
find_dependent_steps <- function(workspace, step_name) {
  checkpoint <- load_checkpoint(workspace)

  dependent_steps <- c()

  # Check each completed step's dependencies
  for (completed_step in checkpoint$completed_steps) {
    step_deps <- checkpoint$step_dependencies[[completed_step]]

    if (!is.null(step_deps) && step_name %in% step_deps) {
      dependent_steps <- c(dependent_steps, completed_step)
    }
  }

  return(unique(dependent_steps))
}

# Recursively find all downstream steps
find_all_downstream_steps <- function(workspace, step_name) {
  all_downstream <- c()
  direct_dependents <- find_dependent_steps(workspace, step_name)

  all_downstream <- c(all_downstream, direct_dependents)

  # Recursively find dependents of dependents
  for (dep_step in direct_dependents) {
    indirect_dependents <- find_all_downstream_steps(workspace, dep_step)
    all_downstream <- c(all_downstream, indirect_dependents)
  }

  return(unique(all_downstream))
}

# Invalidate all dependent steps when an upstream step needs to re-run
invalidate_dependent_steps <- function(workspace, step_name, verbose = TRUE) {
  checkpoint <- load_checkpoint(workspace)

  # Find all downstream steps that need to be invalidated
  steps_to_invalidate <- find_all_downstream_steps(workspace, step_name)

  if (length(steps_to_invalidate) > 0) {
    if (verbose) {
      cat("\n")
      cat("================================================================\n")
      cat("Invalidating dependent steps due to re-run of:", step_name, "\n")
      cat("================================================================\n")
      cat("The following steps will be re-executed:\n")
      for (s in steps_to_invalidate) {
        cat("  -", s, "\n")
      }
      cat("================================================================\n\n")
    }

    log_message(
      workspace,
      paste("Invalidating", length(steps_to_invalidate), "dependent steps due to re-run of", step_name),
      "INFO"
    )

    # Remove from completed steps
    checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, steps_to_invalidate)

    # Clear config hashes for invalidated steps
    for (step in steps_to_invalidate) {
      checkpoint$config_hashes[[step]] <- NULL
      checkpoint$config_details[[step]] <- NULL
    }

    save_checkpoint(workspace, checkpoint)
  }

  return(steps_to_invalidate)
}

# Main function to execute steps with checkpoint support
execute_step <- function(workspace, step_name, step_function,
                         output_files = NULL, cleanup_patterns = NULL,
                         dependencies = NULL, force_rerun = FALSE,
                         config_to_track = NULL, ...) {
  checkpoint <- load_checkpoint(workspace)

  # Save dependencies for this step (for future dependency tracking)
  if (!is.null(dependencies)) {
    checkpoint$step_dependencies[[step_name]] <- dependencies
    save_checkpoint(workspace, checkpoint)
  }

  # Check for interrupted step and reset if necessary
  if (!is.null(checkpoint$current_step) && checkpoint$current_step == step_name) {
    log_message(
      workspace,
      paste("Step", step_name, "was interrupted previously, resetting"), "WARN"
    )
    checkpoint$current_step <- NULL
    checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, step_name)
    save_checkpoint(workspace, checkpoint)
  }

  # Check if dependent steps are completed
  if (!is.null(dependencies)) {
    missing_deps <- setdiff(dependencies, checkpoint$completed_steps)
    if (length(missing_deps) > 0) {
      stop(paste("Missing dependent steps:", paste(missing_deps, collapse = ", ")))
    }
  }

  # Check if configuration has changed (triggers rerun)
  config_changed <- FALSE
  config_change_info <- NULL
  if (!is.null(config_to_track)) {
    config_change_info <- check_config_changed(workspace, step_name, config_to_track, verbose = TRUE)
    config_changed <- config_change_info$changed

    if (config_changed && !is.null(config_change_info$reason)) {
      log_message(
        workspace,
        paste("Configuration changed for step", step_name, "-", config_change_info$reason), "INFO"
      )

      # Invalidate all dependent steps
      invalidate_dependent_steps(workspace, step_name, verbose = TRUE)

      # Reload checkpoint after invalidation
      checkpoint <- load_checkpoint(workspace)
    }
  }

  # Check if step is already completed and not forced to rerun
  if (step_name %in% checkpoint$completed_steps && !force_rerun && !config_changed) {
    # Verify output file integrity
    all_files_ok <- TRUE
    if (!is.null(output_files)) {
      for (file in output_files) {
        full_path <- file.path(workspace$base_dir, file)
        expected_hash <- checkpoint$file_hashes[[file]]
        if (!verify_file_integrity(full_path, expected_hash)) {
          log_message(
            workspace, paste("File", file, "corrupted or missing, need to regenerate"), "WARN"
          )
          all_files_ok <- FALSE
          break
        }
      }
    }

    if (all_files_ok) {
      log_message(workspace, paste("Step", step_name, "already completed, skipping"))
      return(invisible(TRUE))
    } else {
      log_message(
        workspace, paste("Step", step_name, "output files have issues, re-executing"), "WARN"
      )
      # Remove from completed list
      checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, step_name)

      # Also invalidate dependent steps
      invalidate_dependent_steps(workspace, step_name, verbose = TRUE)
      checkpoint <- load_checkpoint(workspace)
    }
  }

  # If config changed, remove from completed steps (already done above, but ensure)
  if (config_changed) {
    checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, step_name)
  }

  log_message(workspace, paste("Starting execution of step:", step_name))
  checkpoint$current_step <- step_name
  checkpoint$step_start_time <- Sys.time()
  save_checkpoint(workspace, checkpoint)

  # Clean up potentially incomplete files
  if (!is.null(cleanup_patterns)) {
    cleanup_step_files(workspace, step_name, cleanup_patterns)
  }

  # Execute step with enhanced error handling
  tryCatch(
    {
      result <- step_function(workspace, ...)

      # Reload checkpoint (it might have been modified during step execution).
      # current_step is still set to THIS step here, so the interrupted-state
      # cleanup must not run: that state is the one being completed, not a
      # leftover from a crashed session.
      checkpoint <- load_checkpoint(workspace, reset_interrupted = FALSE)

      # Verify output files and record hashes
      if (!is.null(output_files)) {
        for (file in output_files) {
          full_path <- file.path(workspace$base_dir, file)
          if (file.exists(full_path)) {
            checkpoint$file_hashes[[file]] <- calculate_file_hash(full_path)
            log_message(workspace, paste("Generated file:", file))
          } else {
            log_message(
              workspace, paste("Warning: Expected output file not generated:", file), "WARN"
            )
          }
        }
      }

      # Save configuration hash and details if tracking
      if (!is.null(config_to_track)) {
        checkpoint$config_hashes[[step_name]] <- calculate_object_hash(config_to_track)
        checkpoint$config_details[[step_name]] <- config_to_track
      }

      # Mark step as completed
      checkpoint$completed_steps <- unique(c(checkpoint$completed_steps, step_name))
      checkpoint$current_step <- NULL
      checkpoint$step_start_time <- NULL
      save_checkpoint(workspace, checkpoint)

      log_message(workspace, paste("Step", step_name, "completed successfully"))
      return(result)
    },
    error = function(e) {
      log_message(workspace, paste("Step", step_name, "execution failed:", e$message), "ERROR")
      if (!is.null(cleanup_patterns)) {
        cleanup_step_files(workspace, step_name, cleanup_patterns)
      }
      # Clear current step on error
      checkpoint <- load_checkpoint(workspace)
      checkpoint$current_step <- NULL
      checkpoint$step_start_time <- NULL
      save_checkpoint(workspace, checkpoint)
      stop(e)
    },
    interrupt = function(int) {
      log_message(workspace, paste("Step", step_name, "was interrupted by user"), "WARN")
      if (!is.null(cleanup_patterns)) {
        cleanup_step_files(workspace, step_name, cleanup_patterns)
      }
      # Clear current step on interrupt
      checkpoint <- load_checkpoint(workspace)
      checkpoint$current_step <- NULL
      checkpoint$step_start_time <- NULL
      save_checkpoint(workspace, checkpoint)
      stop("Analysis interrupted by user")
    }
  )
}

# Check project status
check_project_status <- function(project_name = "proteomics_project", base_dir = "./res/") {
  workspace <- create_workspace(project_name, base_dir)

  if (!file.exists(workspace$checkpoint_file)) {
    cat("Project", project_name, "does not exist or has not started\n")
    return(invisible(NULL))
  }

  checkpoint <- fromJSON(workspace$checkpoint_file)

  cat("=== Project Status ===\n")
  cat("Project:", project_name, "\n")
  cat("Base directory:", base_dir, "\n")
  cat("Completed steps:", ifelse(
    length(checkpoint$completed_steps) == 0,
    "None",
    paste(checkpoint$completed_steps, collapse = ", ")
  ), "\n")
  cat("Current step:", ifelse(is.null(checkpoint$current_step), "None", checkpoint$current_step), "\n")
  cat("Last update:", checkpoint$last_update, "\n")

  # Check for interrupted steps
  if (!is.null(checkpoint$current_step)) {
    cat("*** WARNING: Found interrupted step '", checkpoint$current_step, "' ***\n", sep = "")
    cat("This step will be restarted on next run.\n")
  }

  # Show step dependencies
  if (length(checkpoint$step_dependencies) > 0) {
    cat("\n=== Step Dependencies ===\n")
    for (step in names(checkpoint$step_dependencies)) {
      deps <- checkpoint$step_dependencies[[step]]
      if (!is.null(deps) && length(deps) > 0) {
        cat("  ", step, " <- ", paste(deps, collapse = ", "), "\n", sep = "")
      }
    }
  }

  # Show tracked configurations with details
  if (length(checkpoint$config_details) > 0) {
    cat("\n=== Tracked Configurations ===\n")
    for (step in names(checkpoint$config_details)) {
      cat("\n[", step, "]\n", sep = "")
      config <- checkpoint$config_details[[step]]
      if (is.list(config)) {
        for (key in names(config)) {
          val <- config[[key]]
          if (is.null(val)) {
            cat("  ", key, ": NULL\n", sep = "")
          } else if (is.list(val)) {
            cat("  ", key, ": ", paste(names(val), "=", unlist(val), collapse = ", "), "\n", sep = "")
          } else {
            cat("  ", key, ": ", paste(as.character(val), collapse = ", "), "\n", sep = "")
          }
        }
      }
    }
    cat("\n")
  }

  # Show file integrity status
  if (length(checkpoint$file_hashes) > 0) {
    cat("=== File Integrity Check ===\n")
    for (file in names(checkpoint$file_hashes)) {
      full_path <- file.path(base_dir, file)
      if (file.exists(full_path)) {
        current_hash <- calculate_file_hash(full_path)
        if (current_hash == checkpoint$file_hashes[[file]]) {
          cat("  ✓", file, "\n")
        } else {
          cat("  ✗", file, "- CORRUPTED\n")
        }
      } else {
        cat("  ✗", file, "- MISSING\n")
      }
    }
  }

  cat("=============================\n\n")

  # Show recent logs
  if (file.exists(workspace$log_file)) {
    cat("Recent logs (last 10 lines):\n")
    log_lines <- readLines(workspace$log_file)
    recent_logs <- tail(log_lines, 10)
    cat(paste(recent_logs, collapse = "\n"), "\n")
  }

  return(invisible(checkpoint))
}

# Reset interrupted step
reset_interrupted_step <- function(project_name = "proteomics_project", base_dir = "./res/") {
  workspace <- create_workspace(project_name, base_dir)

  if (!file.exists(workspace$checkpoint_file)) {
    cat("No checkpoint file found for project:", project_name, "\n")
    return(invisible(NULL))
  }

  checkpoint <- fromJSON(workspace$checkpoint_file)

  if (!is.null(checkpoint$current_step)) {
    interrupted_step <- checkpoint$current_step
    cat("Resetting interrupted step:", interrupted_step, "\n")

    # Remove from completed steps if it was there
    checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, interrupted_step)
    checkpoint$current_step <- NULL
    checkpoint$step_start_time <- NULL

    save_checkpoint(workspace, checkpoint)
    log_message(workspace, paste("Manual reset of interrupted step:", interrupted_step))

    cat("Step", interrupted_step, "has been reset and will run from the beginning.\n")
  } else {
    cat("No interrupted step found.\n")
  }
}

# Verify all checkpoint files
verify_checkpoint_files <- function(project_name = "proteomics_project", base_dir = "./res/") {
  workspace <- create_workspace(project_name, base_dir)

  if (!file.exists(workspace$checkpoint_file)) {
    cat("No checkpoint file found for project:", project_name, "\n")
    return(invisible(FALSE))
  }

  checkpoint <- fromJSON(workspace$checkpoint_file)

  cat("=== File Verification ===\n")
  all_ok <- TRUE

  for (file in names(checkpoint$file_hashes)) {
    full_path <- file.path(base_dir, file)
    expected_hash <- checkpoint$file_hashes[[file]]

    if (!file.exists(full_path)) {
      cat("✗ MISSING:", file, "\n")
      all_ok <- FALSE
    } else {
      current_hash <- calculate_file_hash(full_path)
      if (current_hash == expected_hash) {
        cat("✓ OK:", file, "\n")
      } else {
        cat("✗ CORRUPTED:", file, "(hash mismatch)\n")
        all_ok <- FALSE
      }
    }
  }

  cat("========================\n")

  if (all_ok) {
    cat("All files are intact and valid.\n")
  } else {
    cat("Some files are missing or corrupted. They will be regenerated on next run.\n")
  }

  return(invisible(all_ok))
}

# Force rerun specific steps (and their dependents)
force_rerun_steps <- function(step_names, project_name = "proteomics_project",
                              base_dir = "./res/", include_dependents = TRUE) {
  workspace <- create_workspace(project_name, base_dir)
  checkpoint <- load_checkpoint(workspace)

  all_steps_to_rerun <- step_names

  # Find and include dependent steps if requested
  if (include_dependents) {
    for (step in step_names) {
      dependents <- find_all_downstream_steps(workspace, step)
      all_steps_to_rerun <- c(all_steps_to_rerun, dependents)
    }
    all_steps_to_rerun <- unique(all_steps_to_rerun)
  }

  checkpoint$completed_steps <- setdiff(checkpoint$completed_steps, all_steps_to_rerun)

  # Also clear config hashes and details for these steps
  for (step in all_steps_to_rerun) {
    checkpoint$config_hashes[[step]] <- NULL
    checkpoint$config_details[[step]] <- NULL
  }

  save_checkpoint(workspace, checkpoint)
  log_message(workspace, paste("Forced rerun of steps:", paste(all_steps_to_rerun, collapse = ", ")))
  cat("Steps marked for rerun:", paste(all_steps_to_rerun, collapse = ", "), "\n")

  return(invisible(all_steps_to_rerun))
}

# Clean project (restart from beginning)
clean_project <- function(project_name = "proteomics_project", base_dir = "./res/") {
  workspace <- create_workspace(project_name, base_dir)
  if (file.exists(workspace$checkpoint_file)) {
    file.remove(workspace$checkpoint_file)
  }
  if (file.exists(workspace$log_file)) {
    file.remove(workspace$log_file)
  }
  cat("Project", project_name, "cleaned, next run will start from beginning\n")
}