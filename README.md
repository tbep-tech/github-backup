
# github-backup

<!-- badges: start -->
[![archive](https://github.com/tbep-tech/github-backup/workflows/archive/badge.svg)](https://github.com/tbep-tech/github-backup/actions)
<!-- badges: end -->

This repository is used to create an archive of all repositories in the tbep-tech GitHub organization page.  Each repository is archived as a .tar.gz file and then uploaded to Amazon S3 services on a weekly basis.  Motivation for this workflow was created from an rOpenSci blog post on [2022/3/22](https://ropensci.org/blog/2022/03/22/safeguards-and-backups-for-github-organizations/).  Click the archive badge above to see the archive log.  

Weekly runs only back up repositories that changed since their last archive in S3.  A repository is backed up if it has no archive yet, if it had pushes or settings changes, or if it had issue or pull request activity since the last backup.  The [log.txt](log.txt) file lists the repositories backed up in the latest run and the last backup time of the repositories that were skipped.  Private repositories are counted but not named in the log.

To back up all repositories regardless of changes, open the archive workflow in the Actions tab, click "Run workflow", and check the full backup option.  

