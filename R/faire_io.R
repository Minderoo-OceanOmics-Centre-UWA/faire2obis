### R/faire_io.R
#
# Shared FAIRe file-reading helper, used by every build_* function below.
# Kept separate since it has no dependency on pipeline state - just an
# .xlsx sheet in, a tibble out.

#' Read a FAIRe sheet that has the 3-row header structure
#' (row 1 = requirement_level_code, row 2 = section, row 3 = actual
#' column names, row 4+ = data).
read_faire_sheet <- function(path, sheet) {
  raw <- readxl::read_excel(path, sheet = sheet, col_names = FALSE)
  col_names <- as.character(raw[3, ])
  data <- raw[-(1:3), ]
  names(data) <- col_names
  data
}
