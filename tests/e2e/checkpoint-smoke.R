#!/usr/bin/env Rscript
# checkpoint-smoke.R — verify execute_step checkpoint behavior in isolation.
# Usage: Rscript tests/e2e/checkpoint-smoke.R
# Needs only jsonlite + digest (present in the plugin-managed library).
args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args) > 0) args[1] else getwd()
source(file.path(root, "r", "utils", "checkpoint.R"))

tmp <- tempfile("ckpt-smoke-")
dir.create(tmp)
ws <- create_workspace("smoke", file.path(tmp, "res"))
step_fn <- function(ws, ...) {
  writeLines("ok", file.path(ws$base_dir, "out.txt"))
}

# 1) A normal step completes and lands in completed_steps.
execute_step(ws, "step_a", step_fn, output_files = "out.txt")

# 2) A second step must NOT trigger the "Detected interrupted step" warning:
#    the current_step written during execution belongs to the step being
#    finished, not a crashed session.
log_before <- readLines(ws$log_file)
execute_step(ws, "step_b", step_fn, output_files = "out.txt")
log_after <- readLines(ws$log_file)
new_lines <- setdiff(log_after, log_before)
if (any(grepl("Detected interrupted", new_lines))) {
  stop("FAIL: false interrupted-step warning during normal execution\n", paste(new_lines, collapse = "\n"))
}

# 3) Checkpoint state is consistent after both steps.
cp <- load_checkpoint(ws, reset_interrupted = FALSE)
stopifnot(all(c("step_a", "step_b") %in% cp$completed_steps))
stopifnot(is.null(cp$current_step))

# 4) A stale current_step (simulating a crashed session) IS cleaned up.
cp$current_step <- "step_c"
cp$completed_steps <- unique(c(cp$completed_steps, "step_c"))
save_checkpoint(ws, cp)
cp2 <- load_checkpoint(ws)
stopifnot(is.null(cp2$current_step))
stopifnot(!"step_c" %in% cp2$completed_steps)

# 5) Already-completed steps are skipped without re-execution.
counter <- new.env(); counter$n <- 0
counting_fn <- function(ws, ...) { counter$n <- counter$n + 1; writeLines("ok", file.path(ws$base_dir, "out.txt")) }
execute_step(ws, "step_a", counting_fn, output_files = "out.txt")
stopifnot(counter$n == 0)  # skipped, not re-run

cat("CHECKPOINT_SMOKE_OK\n")
