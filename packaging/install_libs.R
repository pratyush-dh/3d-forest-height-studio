# Installs the app's R packages (and their dependencies) from CRAN *binaries* into the bundle's own library.
# Run with the bundled Rscript.exe by build.ps1; BUNDLE_LIB = target library folder.
lib <- Sys.getenv("BUNDLE_LIB")
stopifnot(nzchar(lib))
dir.create(lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(normalizePath(lib, winslash = "/"), .Library)) # only the bundle: no user or site libraries

pkgs <- c("shiny", "bslib", "sf", "terra", "geodata", "classInt", "jsonlite", "callr", "httpuv", "later")
options(repos = c(CRAN = "https://cloud.r-project.org"), timeout = 3600)
install.packages(pkgs, lib = lib, type = "binary", dependencies = NA, quiet = TRUE)

missing <- pkgs[!vapply(pkgs, function(p) requireNamespace(p, lib.loc = c(lib, .Library), quietly = TRUE), logical(1))]
if (length(missing)) stop("Could not install: ", paste(missing, collapse = ", "))
inst <- installed.packages(lib.loc = lib)
cat(sprintf("Installed %d packages into the bundle library (%s).\n", nrow(inst), lib))
