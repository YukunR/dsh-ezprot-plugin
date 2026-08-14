#!/usr/bin/env Rscript
# export_xlsx.R <input.xlsx> <output.tsv> [sheet]
# Plugin helper: convert one Excel sheet to a tab-separated file with
# NaN markers, so the JS importer can inspect/tidy it without a JS
# spreadsheet dependency.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: export_xlsx.R <input.xlsx> <output.tsv> [sheet]")
input <- args[1]
output <- args[2]
sheet <- if (length(args) >= 3 && nzchar(args[3])) args[3] else NULL

suppressPackageStartupMessages(library(readxl))

if (is.null(sheet)) {
  sheets <- excel_sheets(input)
  sheet <- sheets[1]
  cat("sheets:", paste(sheets, collapse = "|"), "\n")
}

data <- read_excel(path = input, sheet = sheet, col_names = TRUE, .name_repair = "unique")
write.table(data,
  file = output,
  sep = "\t",
  row.names = FALSE,
  quote = FALSE,
  na = "NaN"
)
cat("exported:", output, "\n")
