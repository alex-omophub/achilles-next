# Dependency installation inputs are hashed by CI independently of package prose.
dir.create(Sys.getenv('R_LIBS'),recursive=TRUE,showWarnings=FALSE)
.libPaths(c(Sys.getenv('R_LIBS'),.libPaths()))
install.packages(c('remotes','jsonlite','digest','httpuv'),repos='https://cloud.r-project.org')
remotes::install_version('DatabaseConnector',version='6.3.2',upgrade='never',repos='https://cloud.r-project.org')
