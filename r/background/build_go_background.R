#!/usr/bin/env Rscript
# build_go_background.R
# Builds GO background database for proteomics enrichment analysis.
# Outputs in the same format as all_uniprot_go_background.csv (UNIPROT,GO,GONAME,ONTOLOGY).
#
# Usage:
#   # Preferred: from UniProt download
#   Rscript build_go_background.R --method uniprot --uniprot-file /path/to/uniprot.tsv --output /path/to/go_background.csv
#
#   # Alternative: from Bioconductor org.*.eg.db
#   Rscript build_go_background.R --method bioconductor --org-package org.Mm.eg.db --output /path/to/go_background.csv
#
# Required packages: optparse, dplyr, tidyr, GO.db
# For bioconductor method: additionally requires the org.*.eg.db package for your organism

suppressPackageStartupMessages({
  if (!requireNamespace("optparse", quietly = TRUE)) {
    install.packages("optparse", repos = "https://cloud.r-project.org")
  }
  library(optparse)
})

option_list <- list(
  make_option("--method", type = "character", default = "uniprot",
              help = "Method to build GO background: 'uniprot' (preferred) or 'bioconductor' [default: %default]"),
  make_option("--uniprot-file", type = "character", default = NULL,
              help = "Path to UniProt TSV file (required for --method uniprot). Must contain columns: Entry, Gene.Ontology.IDs"),
  make_option("--org-package", type = "character", default = NULL,
              help = "Bioconductor organism package name (required for --method bioconductor, e.g. org.Mm.eg.db)"),
  make_option("--output", type = "character", default = "./go_background.csv",
              help = "Output file path for GO background CSV [default: %default]"),
  make_option("--evidence-filter", type = "character", default = "all",
              help = "Evidence code filter for bioconductor method: 'all', 'experimental', 'htp', 'computational' [default: %default]")
)

opt <- parse_args(OptionParser(option_list = option_list,
                                description = "Build GO background database for proteomics enrichment analysis"))

# ── Validation ────────────────────────────────────────────────────────────────
if (!opt$method %in% c("uniprot", "bioconductor")) {
  stop("--method must be 'uniprot' or 'bioconductor'")
}
if (opt$method == "uniprot" && is.null(opt[["uniprot-file"]])) {
  stop("--uniprot-file is required when --method uniprot")
}
if (opt$method == "bioconductor" && is.null(opt[["org-package"]])) {
  stop("--org-package is required when --method bioconductor (e.g., org.Mm.eg.db)")
}

# Create output directory if needed
out_dir <- dirname(opt$output)
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)

# ── Load shared packages ───────────────────────────────────────────────────────
for (pkg in c("dplyr", "tidyr")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    install.packages(pkg, repos = "https://cloud.r-project.org")
  }
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
}

# GO.db provides GO ID → GO name + ontology category mapping
if (!requireNamespace("GO.db", quietly = TRUE)) {
  if (!requireNamespace("BiocManager", quietly = TRUE)) {
    install.packages("BiocManager", repos = "https://cloud.r-project.org")
  }
  BiocManager::install("GO.db", ask = FALSE)
}
suppressPackageStartupMessages(library(GO.db))

# ── Helper: look up GO names using GO.db ─────────────────────────────────────
lookup_go_names <- function(go_ids) {
  # Returns a data frame with columns: GO, GONAME, ONTOLOGY
  go_ids_clean <- unique(go_ids[!is.na(go_ids) & go_ids != ""])

  go_terms <- suppressMessages(
    AnnotationDbi::select(GO.db,
                          keys    = go_ids_clean,
                          columns = c("TERM", "ONTOLOGY"),
                          keytype = "GOID")
  )

  go_terms <- go_terms %>%
    rename(GO = GOID, GONAME = TERM) %>%
    filter(!is.na(GONAME), !is.na(ONTOLOGY)) %>%
    distinct()

  return(go_terms)
}

# ── Method 1: UniProt TSV ─────────────────────────────────────────────────────
build_from_uniprot <- function(uniprot_file, output_path) {
  message("Reading UniProt TSV: ", uniprot_file)

  uniprot_dat <- read.delim(uniprot_file, stringsAsFactors = FALSE)

  # Detect column names (UniProt API may vary)
  col_names <- colnames(uniprot_dat)

  # Find Entry/accession column
  entry_col <- col_names[grepl("^Entry$", col_names, ignore.case = TRUE)]
  if (length(entry_col) == 0) {
    entry_col <- col_names[1]
    message("  Using first column as UniProt accession: ", entry_col)
  }

  # Find GO IDs column
  go_col <- col_names[grepl("Gene.Ontology.IDs|Gene Ontology IDs|GO.*ID|go_id", col_names, ignore.case = TRUE)]
  if (length(go_col) == 0) {
    stop("Cannot find GO IDs column. Expected column name containing 'Gene Ontology IDs' or 'GO ID'.\n",
         "Available columns: ", paste(col_names, collapse = ", "))
  }
  go_col <- go_col[1]

  message("  Found accession column: '", entry_col, "', GO column: '", go_col, "'")
  message("  Total proteins: ", nrow(uniprot_dat))

  # Select and rename
  uniprot_dat <- uniprot_dat %>%
    dplyr::select(UNIPROT = all_of(entry_col), GO_IDs = all_of(go_col)) %>%
    dplyr::filter(!is.na(GO_IDs), GO_IDs != "")

  # Split multiple GO IDs (separated by "; ")
  uniprot_go <- uniprot_dat %>%
    tidyr::separate_rows(GO_IDs, sep = ";\\s*") %>%
    dplyr::rename(GO = GO_IDs) %>%
    dplyr::filter(!is.na(GO), GO != "") %>%
    dplyr::mutate(GO = trimws(GO)) %>%
    dplyr::distinct()

  message("  Protein-GO pairs before lookup: ", nrow(uniprot_go))

  # Look up GO names and ontology from GO.db
  message("  Looking up GO names from GO.db...")
  go_info <- lookup_go_names(uniprot_go$GO)

  # Merge GO names into results
  result <- uniprot_go %>%
    dplyr::inner_join(go_info, by = "GO") %>%
    dplyr::select(UNIPROT, GO, GONAME, ONTOLOGY) %>%
    dplyr::distinct()

  message("  Final protein-GO pairs: ", nrow(result))
  message("  Unique proteins: ", n_distinct(result$UNIPROT))

  write.csv(result, output_path, row.names = FALSE)
  message("GO background saved to: ", output_path)
}

# ── Method 2: Bioconductor org.*.eg.db ───────────────────────────────────────
build_from_bioconductor <- function(org_package, output_path, evidence_filter = "all") {
  message("Loading Bioconductor package: ", org_package)

  if (!requireNamespace(org_package, quietly = TRUE)) {
    if (!requireNamespace("BiocManager", quietly = TRUE)) {
      install.packages("BiocManager", repos = "https://cloud.r-project.org")
    }
    BiocManager::install(org_package, ask = FALSE)
  }
  suppressPackageStartupMessages(library(org_package, character.only = TRUE))

  org_db <- get(org_package)

  message("  Extracting UniProt IDs...")
  pro_ids <- AnnotationDbi::keys(org_db, "UNIPROT")
  message("  Total UniProt IDs: ", length(pro_ids))

  message("  Querying GO annotations...")
  uniprot_go <- suppressMessages(
    AnnotationDbi::select(org_db,
                          keys    = pro_ids,
                          keytype = "UNIPROT",
                          columns = c("GO", "ONTOLOGY", "EVIDENCE"))
  )

  uniprot_go <- na.omit(uniprot_go)

  # Apply evidence filter
  experimental_codes <- c("EXP", "IDA", "IPI", "IMP", "IGI", "IEP")
  htp_codes          <- c("HTP", "HDA", "HMP", "HGI", "HEP")
  computational_codes <- c("ISS", "ISO", "ISA", "ISM", "IGC", "IBA",
                            "IBD", "IKR", "IRD", "RCA")

  if (evidence_filter == "experimental") {
    uniprot_go <- uniprot_go[uniprot_go$EVIDENCE %in% experimental_codes, ]
    message("  Filtered to experimental evidence: ", nrow(uniprot_go), " annotations")
  } else if (evidence_filter == "htp") {
    uniprot_go <- uniprot_go[uniprot_go$EVIDENCE %in% htp_codes, ]
    message("  Filtered to HTP evidence: ", nrow(uniprot_go), " annotations")
  } else if (evidence_filter == "computational") {
    uniprot_go <- uniprot_go[uniprot_go$EVIDENCE %in% computational_codes, ]
    message("  Filtered to computational evidence: ", nrow(uniprot_go), " annotations")
  } else {
    message("  Using all evidence codes: ", nrow(uniprot_go), " annotations")
  }

  message("  Looking up GO names from GO.db...")
  go_info <- lookup_go_names(uniprot_go$GO)

  result <- uniprot_go %>%
    dplyr::inner_join(go_info, by = c("GO", "ONTOLOGY")) %>%
    dplyr::select(UNIPROT, GO, GONAME, ONTOLOGY) %>%
    dplyr::distinct()

  message("  Final protein-GO pairs: ", nrow(result))
  message("  Unique proteins: ", n_distinct(result$UNIPROT))

  write.csv(result, output_path, row.names = FALSE)
  message("GO background saved to: ", output_path)
}

# ── Main ──────────────────────────────────────────────────────────────────────
if (opt$method == "uniprot") {
  build_from_uniprot(
    uniprot_file = opt[["uniprot-file"]],
    output_path  = opt$output
  )
} else {
  build_from_bioconductor(
    org_package     = opt[["org-package"]],
    output_path     = opt$output,
    evidence_filter = opt[["evidence-filter"]]
  )
}
