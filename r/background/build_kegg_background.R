#!/usr/bin/env Rscript
# build_kegg_background.R
# Builds KEGG pathway background database for proteomics enrichment analysis.
# Downloads data from KEGG REST API and UniProt, then assembles the background.
# Outputs in the same format as pathfromKegg_mmu.txt (UNIPROT\tPATH\tPATHNAME, tab-delimited).
#
# Usage:
#   Rscript build_kegg_background.R --kegg-code mmu --species-name "Mus musculus" --output /path/to/kegg_background.txt
#
#   # With custom UniProt taxon for reviewed proteins filter
#   Rscript build_kegg_background.R --kegg-code hsa --species-name "Homo sapiens" \
#     --uniprot-taxon 9606 --output /path/to/kegg_background.txt
#
# Required packages: optparse
# Internet access required to download KEGG and UniProt data.

suppressPackageStartupMessages({
  if (!requireNamespace("optparse", quietly = TRUE)) {
    install.packages("optparse", repos = "https://cloud.r-project.org")
  }
  library(optparse)
})

option_list <- list(
  make_option("--kegg-code", type = "character", default = NULL,
              help = "KEGG organism code (e.g., hsa, mmu, rno). Required."),
  make_option("--species-name", type = "character", default = NULL,
              help = "Full species name for KEGG pathway name cleanup (e.g., 'Mus musculus'). Required."),
  make_option("--uniprot-taxon", type = "character", default = NULL,
              help = "UniProt taxonomy ID for downloading reviewed proteins (e.g., 10090 for mouse). If not provided, no reviewed-protein filter is applied."),
  make_option("--output", type = "character", default = "./kegg_background.txt",
              help = "Output file path for KEGG background TXT [default: %default]"),
  make_option("--temp-dir", type = "character", default = NULL,
              help = "Directory for temporary downloaded files. If not provided, uses a temp directory.")
)

opt <- parse_args(OptionParser(option_list = option_list,
                                description = "Build KEGG pathway background database from KEGG REST API"))

# ── Validation ────────────────────────────────────────────────────────────────
if (is.null(opt[["kegg-code"]])) {
  stop("--kegg-code is required (e.g., hsa, mmu, rno)")
}
if (is.null(opt[["species-name"]])) {
  stop("--species-name is required (e.g., 'Mus musculus')")
}

kegg_code    <- opt[["kegg-code"]]
species_name <- opt[["species-name"]]
out_path     <- opt$output
taxon_id     <- opt[["uniprot-taxon"]]

# Create output directory if needed
out_dir <- dirname(out_path)
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# Temp directory for downloads
if (is.null(opt[["temp-dir"]])) {
  temp_dir <- tempdir()
} else {
  temp_dir <- opt[["temp-dir"]]
  if (!dir.exists(temp_dir)) dir.create(temp_dir, recursive = TRUE)
}

# ── Helper: download file with retry ─────────────────────────────────────────
download_with_retry <- function(url, dest, max_tries = 3) {
  for (attempt in seq_len(max_tries)) {
    tryCatch({
      download.file(url, dest, quiet = TRUE, mode = "wb")
      if (file.exists(dest) && file.size(dest) > 0) return(invisible(TRUE))
    }, error = function(e) {
      message("  Attempt ", attempt, " failed: ", conditionMessage(e))
    })
    if (attempt < max_tries) Sys.sleep(2)
  }
  stop("Failed to download: ", url)
}

# ── Step 1: Download KEGG data ────────────────────────────────────────────────
message("=== Downloading KEGG data for organism: ", kegg_code, " ===")

# 1a. Gene-to-UniProt mapping
gene_uniprot_url  <- paste0("https://rest.kegg.jp/conv/", kegg_code, "/uniprot/")
gene_uniprot_file <- file.path(temp_dir, paste0("kegg_gene_uniprot_", kegg_code, ".txt"))
message("  Downloading gene-UniProt mapping...")
download_with_retry(gene_uniprot_url, gene_uniprot_file)

# 1b. Gene-to-pathway mapping
gene_pathway_url  <- paste0("https://rest.kegg.jp/link/pathway/", kegg_code)
gene_pathway_file <- file.path(temp_dir, paste0("kegg_gene_pathway_", kegg_code, ".txt"))
message("  Downloading gene-pathway mapping...")
download_with_retry(gene_pathway_url, gene_pathway_file)

# 1c. Pathway names
pathway_list_url  <- paste0("https://rest.kegg.jp/list/pathway/", kegg_code)
pathway_list_file <- file.path(temp_dir, paste0("kegg_pathway_list_", kegg_code, ".txt"))
message("  Downloading pathway names...")
download_with_retry(pathway_list_url, pathway_list_file)

# ── Step 2: Parse KEGG data ───────────────────────────────────────────────────
message("=== Parsing KEGG data ===")

# Gene-UniProt: columns are "up:P12345\tkegg_code:12345"
gene_uniprot <- read.delim(gene_uniprot_file, header = FALSE,
                            col.names = c("UNIPROT_raw", "Kegg"),
                            stringsAsFactors = FALSE)
gene_uniprot$UNIPROT <- gsub("up:", "", gene_uniprot$UNIPROT_raw)
gene_uniprot$Kegg    <- gene_uniprot$Kegg  # e.g., "mmu:12345"
gene_uniprot <- gene_uniprot[, c("Kegg", "UNIPROT")]
message("  Gene-UniProt pairs: ", nrow(gene_uniprot))

# Gene-Pathway: columns are "kegg_code:12345\tpath:mmuXXXXX"
gene_pathway <- read.delim(gene_pathway_file, header = FALSE,
                             col.names = c("Kegg", "PATH_raw"),
                             stringsAsFactors = FALSE)
# Extract pathway ID (e.g., "path:mmu05322" → "mmu05322")
gene_pathway$PATH <- gsub("path:(.*)", "\\1", gene_pathway$PATH_raw)
gene_pathway <- gene_pathway[, c("Kegg", "PATH")]
message("  Gene-pathway pairs: ", nrow(gene_pathway))

# Pathway list: columns are "path:mmuXXXXX\tpathway name - Species (organism) ..."
pathway_list <- read.delim(pathway_list_file, header = FALSE,
                             col.names = c("PATH_raw", "PATHNAME_raw"),
                             stringsAsFactors = FALSE)
pathway_list$PATH <- gsub("path:(.*)", "\\1", pathway_list$PATH_raw)

# Clean pathway name: remove " - Species name (organism)" suffix
# Pattern: "Pathway Name - Mus musculus (mouse)" → "Pathway Name"
species_pattern <- paste0("(.*) - ", gsub("([()])", "\\\\\\1", species_name), ".*")
pathway_list$PATHNAME <- gsub(species_pattern, "\\1", pathway_list$PATHNAME_raw)

# Fallback: remove everything after " - " if pattern didn't match
no_match <- pathway_list$PATHNAME == pathway_list$PATHNAME_raw
if (any(no_match)) {
  pathway_list$PATHNAME[no_match] <- gsub("(.*) - .*", "\\1", pathway_list$PATHNAME_raw[no_match])
}

pathway_list <- pathway_list[, c("PATH", "PATHNAME")]
message("  Pathways: ", nrow(pathway_list))

# ── Step 3: Merge KEGG tables ─────────────────────────────────────────────────
message("=== Merging KEGG tables ===")

# Join: gene-uniprot ⟕ gene-pathway
path_data <- merge(gene_uniprot, gene_pathway, by = "Kegg")

# Join with pathway names
path_data <- merge(path_data, pathway_list, by = "PATH")

path_data <- path_data[, c("UNIPROT", "PATH", "PATHNAME")]
path_data <- unique(path_data)
message("  UNIPROT-PATH pairs before filter: ", nrow(path_data))

# ── Step 4: Filter to reviewed UniProt proteins (optional) ───────────────────
if (!is.null(taxon_id)) {
  message("=== Downloading UniProt reviewed proteins (taxon: ", taxon_id, ") ===")

  uniprot_url <- paste0(
    "https://rest.uniprot.org/uniprotkb/stream?",
    "compressed=false",
    "&fields=accession",
    "&format=tsv",
    "&query=%28*%29+AND+%28model_organism%3A", taxon_id, "%29+AND+%28reviewed%3Atrue%29"
  )

  uniprot_file <- file.path(temp_dir, paste0("uniprot_reviewed_", taxon_id, ".tsv"))
  message("  Downloading from UniProt REST API...")
  download_with_retry(uniprot_url, uniprot_file)

  reviewed <- read.delim(uniprot_file, stringsAsFactors = FALSE)
  reviewed_ids <- reviewed[[1]]  # First column = Entry (accession)
  message("  Reviewed proteins: ", length(reviewed_ids))

  before_filter <- nrow(path_data)
  path_data <- path_data[path_data$UNIPROT %in% reviewed_ids, ]
  message("  UNIPROT-PATH pairs after reviewed filter: ", nrow(path_data),
          " (removed ", before_filter - nrow(path_data), ")")
}

# ── Step 5: Write output ──────────────────────────────────────────────────────
message("=== Writing output ===")
write.table(path_data, out_path, quote = FALSE, sep = "\t", row.names = FALSE)
message("KEGG background saved to: ", out_path)
message("Total UNIPROT-PATH pairs: ", nrow(path_data))
# base R only: this script must run in the minimal docker image, where only
# the manifest packages are guaranteed (dplyr IS present, but the script's
# declared dependency is optparse, so keep the stats dependency-free).
message("Unique proteins: ", length(unique(path_data$UNIPROT)))
message("Unique pathways: ", length(unique(path_data$PATH)))
