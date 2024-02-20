library(gh)
library(aws.s3)

# aws keys
Sys.setenv(
  "AWS_ACCESS_KEY_ID" = Sys.getenv('AWS_ACCESS_KEY_ID'),
  "AWS_SECRET_ACCESS_KEY" = Sys.getenv('AWS_SECRET_ACCESS_KEY')
)

# identify repos in tbep-tech, except this one
repos <- gh::gh(
    "/orgs/{org}/repos",
    org = "tbep-tech",
    type = "all",
    per_page = 100,
    .limit = Inf
  ) |> 
  purrr::map_chr("name") #|> 
  # (\(x) x[!x %in% 'github-backup'])()

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
    org = "tbep-tech",
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
  file_path <- sprintf("%s_migration_archive.tar.gz", repo) 
  curl::curl_download(
    final_url, 
    file_path
  )
 
  # upload to S3
  cat('\tUpload to S3...\n')
  put_object(file_path, bucket = 'tbep-tech-github-backup', multipart = T)

  # remove local file
  file.remove(file_path)
  
}

sink('log.txt')
cat(paste('Successful archive on', Sys.time(), '\n'))
Sys.time() - str
sink()
