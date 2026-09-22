### R/archive_history.R
#
# Persists generated archive .zips to S3 so anyone using the hosted app
# can re-download a past run later WITHOUT re-running the pipeline.
# Needed because shinyapps.io/Posit Connect don't guarantee a running
# app's local disk survives an idle restart, a redeploy, or scaling to
# a second instance - so nothing written only to local disk can be
# relied on to still be there next time someone opens the app.
#
# Credentials and bucket name come from environment variables only,
# never hardcoded (set these as "Environment Variables" in the
# shinyapps.io dashboard for this app, not committed to the repo):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#   FAIRE2OBIS_S3_BUCKET - the bucket name to store archives in
#
# Each project gets ONE canonical archive, at
#   s3://minderoo-oceanomics/biodiversity-public/<project_id>/<project_id>_CoreVersion.zip
# matching this project's existing public S3 folder convention (one
# folder per project id, e.g. .../biodiversity-public/OcOm_2408/...).
# Generating a project's archive again OVERWRITES that same file.
#
# The "History" tab is a LIVE listing of everything actually under the
# biodiversity-public/ prefix in the bucket - not just what this app
# generated (that folder also holds files other tools/people put there,
# e.g. a project's DwC-Archive subfolder from a different pipeline).
# There is deliberately no separate bookkeeping index file for this any
# more (an earlier version kept one, at .../ocom-edna/index.json) - a
# live aws.s3::get_bucket_df() call is simpler, can never drift out of
# sync with reality, and needs no read-modify-write race handling.

# Defaults to the project's known bucket/prefix; still overridable via
# env var (e.g. to point a dev deployment at a separate bucket/prefix).
s3_bucket_name <- function() {
  v <- Sys.getenv("FAIRE2OBIS_S3_BUCKET")
  if (nzchar(v)) v else "minderoo-oceanomics"
}
# Where PUBLIC project zips live - one subfolder per project id, matching
# the existing convention (.../biodiversity-public/OcOm_2408/...). Also
# the prefix the History tab lists everything under.
s3_public_prefix <- function() {
  v <- Sys.getenv("FAIRE2OBIS_S3_PREFIX")
  if (nzchar(v)) v else "biodiversity-public"
}

safe_project_id <- function(project_id) {
  gsub("[^A-Za-z0-9_-]", "_", if (!is.null(project_id) && nzchar(project_id)) project_id else "untitled")
}
project_zip_key <- function(project_id) {
  safe <- safe_project_id(project_id)
  paste0(s3_public_prefix(), "/", safe, "/", safe, "_CoreVersion.zip")
}

#' TRUE if archive history is configured (bucket known AND AWS credentials
#' present). The app hides the whole History UI section, rather than
#' erroring, when this is FALSE - e.g. when running locally during
#' development, where the bucket name defaults but no AWS keys are set.
archive_history_enabled <- function() {
  nzchar(s3_bucket_name()) &&
    nzchar(Sys.getenv("AWS_ACCESS_KEY_ID")) &&
    nzchar(Sys.getenv("AWS_SECRET_ACCESS_KEY"))
}

#' Save a generated archive zip to S3, OVERWRITING that project's
#' existing zip (if any). No separate bookkeeping write - the History
#' tab reads the bucket directly, so uploading the file IS the update.
#'
#' @param zip_path Local path to the already-built .zip file
#' @param project_id Character - determines the S3 folder/filename, so
#'   regenerating the SAME project's archive replaces its previous version
#' @param assay_names Unused (kept for call-site compatibility)
save_archive_to_s3 <- function(zip_path, project_id, assay_names = NULL) {
  bucket <- s3_bucket_name()
  if (!nzchar(bucket)) stop("FAIRE2OBIS_S3_BUCKET is not set - archive history is not configured.")

  key <- project_zip_key(project_id)
  ok <- aws.s3::put_object(file = zip_path, object = key, bucket = bucket)
  if (!isTRUE(ok)) stop("Upload to S3 did not report success.")

  invisible(list(project_id = project_id, s3_key = key))
}

#' List everything under the public prefix in the bucket, newest first,
#' as a data.frame for a table - a live folder listing, not just what
#' this app generated. Folder placeholder entries (zero-byte keys ending
#' in "/", which S3 consoles create when you make an empty folder) are
#' dropped since they're not real files.
#'
#' @return data.frame with columns last_modified, path (key with the
#'   public prefix stripped, for display), size_mb (display string),
#'   s3_key (full key, not for display - used for download); project
#'   (the top-level folder the file lives under, i.e. the project id -
#'   the first path segment, e.g. "OcOm_2408" for
#'   "OcOm_2408/OcOm2408_CoreVersion.zip")
list_archive_history <- function() {
  bucket <- s3_bucket_name()
  empty <- data.frame(
    last_modified = character(), project = character(), path = character(),
    size_mb = character(), s3_key = character(),
    stringsAsFactors = FALSE
  )
  if (!nzchar(bucket)) return(empty)

  prefix <- paste0(s3_public_prefix(), "/")
  objects <- aws.s3::get_bucket_df(bucket = bucket, prefix = prefix, max = Inf)
  if (nrow(objects) == 0) return(empty)

  objects$Size <- as.numeric(objects$Size)
  objects <- objects[objects$Size > 0, , drop = FALSE]
  if (nrow(objects) == 0) return(empty)

  rel_path <- sub(paste0("^", prefix), "", objects$Key)
  df <- data.frame(
    last_modified = objects$LastModified,
    project       = sub("/.*$", "", rel_path),
    path          = rel_path,
    size_mb       = sprintf("%.1f MB", objects$Size / 1024^2),
    s3_key        = objects$Key,
    stringsAsFactors = FALSE
  )
  df[order(df$last_modified, decreasing = TRUE), , drop = FALSE]
}

#' Fetch a previously saved archive's bytes from S3 directly into a local
#' file path (for a downloadHandler's `content` function).
#'
#' @param s3_key The archive's key in the bucket (from list_archive_history())
#' @param dest Local path to write the archive to
fetch_archive_from_s3 <- function(s3_key, dest) {
  bucket <- s3_bucket_name()
  aws.s3::save_object(object = s3_key, bucket = bucket, file = dest)
  invisible(dest)
}
