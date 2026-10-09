# Launch 3D Forest Height Studio.
#   Rscript run_app.R            (or source("run_app.R") from R / RStudio)
# Set STUDIO_NO_BROWSER=1 to start the server without opening a browser tab.
here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) NULL)
if (is.null(here)) {
    args <- commandArgs(trailingOnly = FALSE)
    f <- sub("^--file=", "", args[grep("^--file=", args)])
    here <- if (length(f)) dirname(normalizePath(f)) else getwd()
}
shiny::runApp(file.path(here, "app"), port = 4821,
    launch.browser = !nzchar(Sys.getenv("STUDIO_NO_BROWSER")))
