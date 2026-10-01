library(gh)
library(aws.s3)

# aws keys
Sys.setenv(
  "AWS_ACCESS_KEY_ID" = Sys.getenv('AWS_ACCESS_KEY_ID'),
  "AWS_SECRET_ACCESS_KEY" = Sys.getenv('AWS_SECRET_ACCESS_KEY')
)

org <- 'tbep-tech'
buck <- 'tbep-tech-github-backup'
suffix <- '_migration_archive.tar.gz'

# full backup of all repos if TRUE, otherwise only repos changed since last backup
full <- tolower(Sys.getenv('FULL_BACKUP')) == 'true'

# buffer subtracted from last backup time when checking for changes
buffer <- as.difftime(1, units = 'days')

# list private repo names in log.txt, FALSE because this repo is public
log_private <- FALSE

# identify repos in tbep-tech
repos_all <- gh::gh(
    "/orgs/{org}/repos",
    org = org,
    type = "all",
    per_page = 100,
    .limit = Inf
  )
names(repos_all) <- purrr::map_chr(repos_all, "name")

# parse github and s3 timestamps as UTC
parse_time <- function(x) {
  if (is.null(x)) return(as.POSIXct(NA, tz = 'UTC'))
  as.POSIXct(x, format = '%Y-%m-%dT%H:%M:%OSZ', tz = 'UTC')
}

# last backup time for each repo, from s3 object modified dates
objs <- aws.s3::get_bucket_df(buck, max = Inf)
if (nrow(objs) > 0 && 'Key' %in% names(objs)) {
  objs <- objs[endsWith(objs$Key, suffix), ]
  last_mod <- do.call(c, lapply(objs$LastModified, parse_time))
  names(last_mod) <- sub(paste0(suffix, '$'), '', objs$Key)
} else {
  last_mod <- as.POSIXct(character(0), tz = 'UTC')
}

# check if repo has pushes, metadata changes, or issue/pr activity since last backup
needs_backup <- function(repo_obj, last_mod) {

  repo <- repo_obj$name

  # no archive in s3
  if (!repo %in% names(last_mod)) return(TRUE)

  ref <- last_mod[[repo]] - buffer

  # pushes or repo metadata changes
  changed <- c(parse_time(repo_obj$pushed_at), parse_time(repo_obj$updated_at))
  if (any(changed > ref, na.rm = TRUE)) return(TRUE)

  # issue or pr activity, including comments
  tryCatch({
    issues <- gh::gh(
      "/repos/{owner}/{repo}/issues",
      owner = org,
      repo = repo,
      state = 'all',
      since = format(ref, '%Y-%m-%dT%H:%M:%SZ', tz = 'UTC'),
      per_page = 1,
      .limit = 1
    )
    length(issues) > 0
  },
  error = function(e) TRUE
  )

}

if (full) {
  repos <- names(repos_all)
} else {
  tobackup <- purrr::map_lgl(repos_all, needs_backup, last_mod = last_mod)
  repos <- names(repos_all)[tobackup]
}
skipped <- setdiff(names(repos_all), repos)

cat(paste0(
  ifelse(full, 'Full', 'Incremental'), ' backup: ',
  length(repos), ' of ', length(repos_all), ' repos to back up, ',
  length(skipped), ' skipped\n'
))

handle <- curl::handle_setheaders(
  curl::new_handle(followlocation = FALSE),
  "Authorization" = paste("token", Sys.getenv("GITHUB_PAT")),
  "Accept" = "application/vnd.github.v3+json"
)

get_migration_state <- function(migration_url) {
  status <- gh::gh(migration_url)
  status$state
}

str <- Sys.time()

# backup completion time for each repo
backed_up <- as.POSIXct(character(0), tz = 'UTC')

# archive and upload to s3 for each repo
for(i in seq_along(repos)){

  repo <- repos[i]

  # counter
  msg <- paste0(repo, ', ', i, ' of ', length(repos), '\n')
  cat(msg)
  print(Sys.time() - str)

  # setup and download archive of repo as .tar.gz
  migration <- gh::gh(
    "POST /orgs/{org}/migrations",
    org = org,
    .token = Sys.getenv('GITHUB_PAT'),
    repositories = as.list(repo)
  )

  migration_url <- migration[["url"]]

  while (get_migration_state(migration_url) != "exported") {
    cat("\tWaiting for export to complete...\n")
    Sys.sleep(60)
  }

  url <- sprintf("%s/archive", migration_url)
  req <- curl::curl_fetch_memory(url, handle = handle)
  headers <- curl::parse_headers_list(req$headers)
  final_url <- headers$location
  file_path <- sprintf("%s%s", repo, suffix)
  curl::curl_download(
    final_url,
    file_path
  )

  # upload to S3 in retry
  cat('\tUpload to S3...\n')
  tryCatch(
    put_object(file_path, bucket = buck, multipart = T),
    error = function(e){
      cat('\t\tRetrying...\n')
      put_object(file_path, bucket = buck, multipart = T)
    }
  )
  backed_up[repo] <- Sys.time()

  # remove local file
  file.remove(file_path)

}

# format repo names and backup times for log, private repos summarized as a count
fmt_log <- function(times) {
  if (!log_private) {
    private <- purrr::map_lgl(repos_all[names(times)], "private")
    nprivate <- sum(private)
    times <- times[!private]
  } else {
    nprivate <- 0
  }
  out <- character(0)
  if (length(times) > 0) {
    times <- times[order(names(times))]
    out <- paste0(
      '  ', formatC(names(times), width = -max(nchar(names(times)))), '  ',
      ifelse(is.na(times), 'unknown', format(times, '%Y-%m-%d %H:%M:%S UTC', tz = 'UTC'))
    )
  }
  if (nprivate > 0) out <- c(out, paste0('  (', nprivate, ' private repos not listed)'))
  if (length(out) == 0) out <- '  none'
  out
}

skipped_times <- last_mod[skipped]
names(skipped_times) <- skipped
runtime <- Sys.time() - str

writeLines(
  c(
    paste0(
      'Successful archive on ', format(Sys.time(), '%Y-%m-%d %H:%M:%S UTC', tz = 'UTC'),
      ' (', ifelse(full, 'full', 'incremental'), ')'
    ),
    paste('Run time:', format(round(runtime, 1))),
    paste('Backed up:', length(backed_up), 'of', length(repos_all), 'repos'),
    '',
    'Backed up this run:',
    fmt_log(backed_up),
    '',
    'Skipped (unchanged), last backup:',
    fmt_log(skipped_times)
  ),
  'log.txt'
)
