# Install AchillesNext from a source tarball

## Build the package

From a reviewed commit in a Git checkout, run the following in Bash with R and the digest package available. The build uses the tracked files at that commit. Distribute only the resulting source tarball. The staging directory also contains the extracted source tree. Record the commit and the SHA-256 of the actual tarball for recipients.

```bash
set -euo pipefail
revision=$(git rev-parse --verify 'HEAD^{commit}')
staging=$(mktemp -d)
git archive --format=tar --prefix=AchillesNext/ "$revision" | tar -xf - -C "$staging"
(cd "$staging" && R CMD build --no-build-vignettes --no-manual AchillesNext)
printf 'Commit %s\n' "$revision"
Rscript --vanilla -e 'f <- commandArgs(TRUE)[1]; cat(digest::digest(file=f, algo="sha256"), basename(f), "\n")' "$staging"/AchillesNext_*.tar.gz
```

Review the contents of the selected commit before distribution. Building a working directory directly can include untracked files. The package filters also exclude common credential files, local configuration directories, PostgreSQL JDBC JARs and diagnostics. Source rows, generated results, approved publications and site credentials belong in separate institutional storage.

## Install on a laptop

Transfer the source tarball and verify its SHA-256 against the release record. Prepare R 4.2 or later, an R-compatible build toolchain with a C compiler, a working Java installation for rJava, and installed copies of the packages in `DESCRIPTION` with their dependencies. Stage these for the target operating system, R version and CPU architecture before disconnecting from the internet. The PostgreSQL generation path also needs the configured database endpoint and a JDBC driver provisioned separately.

Choose a writable library. In the directory containing the transferred tarball, substitute its exact filename and the SHA-256 from the release record.

```sh
set -e
archive=./AchillesNext_0.0.0.9000.tar.gz
expected_sha256='replace-with-release-sha256'
Rscript --vanilla -e 'args <- commandArgs(TRUE); stopifnot(identical(digest::digest(file=args[1], algo="sha256"), args[2]))' "$archive" "$expected_sha256"
package_library="$PWD/r-library"
mkdir -p "$package_library"
export R_LIBS="$package_library${R_LIBS:+:$R_LIBS}"
R CMD INSTALL --library="$package_library" "$archive"
Rscript --vanilla -e 'library(AchillesNext); print(packageVersion("AchillesNext"))'
```

The installation includes the browser assets. SQL rendering uses declared source metadata. Generation connects to the configured PostgreSQL engine. To open the result returned by `publishResultRelease()`, run `AchillesNext::viewResults(publication)`. The viewer reads the saved files through a local R session.

The function reference and this guide are available after installation, including when disconnected.

```r
help("renderCharacterizationSql", package = "AchillesNext")
help("viewResults", package = "AchillesNext")
file.show(system.file("guides", "installation.md", package = "AchillesNext", mustWork = TRUE))
```
