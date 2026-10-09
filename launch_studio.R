# Launcher used by the installed app (see packaging/). For development use run_app.R instead.
#  - picks a free port,
#  - re-uses an already running instance (second launch just opens another window),
#  - opens the app in its own chromeless Edge/Chrome window (falls back to the default browser),
#  - the app stops itself when the last window is closed (STUDIO_AUTOCLOSE).
args <- commandArgs(trailingOnly = FALSE)
here <- dirname(normalizePath(sub("^--file=", "", args[grep("^--file=", args)])))

data_root <- Sys.getenv("STUDIO_DATA_DIR",
    unset = file.path(Sys.getenv("LOCALAPPDATA", unset = tempdir()), "3D Forest Height Studio"))
dir.create(data_root, showWarnings = FALSE, recursive = TRUE)
Sys.setenv(STUDIO_DATA_DIR = data_root, STUDIO_AUTOCLOSE = "1")
if (!nzchar(Sys.getenv("PROCESSOR_ARCHITECTURE"))) Sys.setenv(PROCESSOR_ARCHITECTURE = "AMD64") # libuv needs it

find_browser <- function() {
    roots <- unique(Sys.getenv(c("ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA")))
    cand <- c(file.path(roots, "Microsoft", "Edge", "Application", "msedge.exe"),
              file.path(roots, "Google", "Chrome", "Application", "chrome.exe"))
    cand <- cand[file.exists(cand)]
    if (length(cand)) cand[1] else NA_character_
}

open_window <- function(url) {
    if (nzchar(Sys.getenv("STUDIO_NO_WINDOW"))) return(invisible(NULL)) # used by automated tests
    exe <- find_browser()
    if (is.na(exe)) return(utils::browseURL(url))
    profile <- file.path(data_root, "window-profile")
    dir.create(profile, showWarnings = FALSE, recursive = TRUE)
    args <- c(
        paste0("--app=", url),
        paste0("--user-data-dir=", normalizePath(profile, winslash = "\\", mustWork = FALSE)),
        "--window-size=1500,950",
        "--no-first-run", "--no-default-browser-check",
        # The app window uses its own, empty browser profile. Without these two flags Edge signs that new
        # profile in with the Windows account, syncs it and installs the user's extensions, whose welcome
        # pages then open on top of the app.
        "--disable-sync", "--disable-extensions"
    )
    extra <- Sys.getenv("STUDIO_EDGE_ARGS")           # for automated tests only, e.g. --remote-debugging-port=9444
    if (nzchar(extra)) args <- c(args, strsplit(trimws(extra), " +")[[1]])
    # system2() does NOT quote arguments: a path with spaces ("3D Forest Height Studio") would be split into several
    # arguments, and Edge would open the pieces as web pages. Quote anything that contains whitespace.
    args <- vapply(args, function(a) if (grepl("[[:space:]]", a)) shQuote(a, type = "cmd") else a, character(1), USE.NAMES = FALSE)
    system2(exe, args, wait = FALSE)
}

is_alive <- function(port) {
    !is.null(tryCatch(curlGetHeaders(sprintf("http://127.0.0.1:%d/", port), timeout = 3), error = function(e) NULL))
}

state_file <- file.path(data_root, "running-port.txt")
if (file.exists(state_file)) {
    old <- suppressWarnings(as.integer(readLines(state_file, n = 1, warn = FALSE)))
    if (!is.na(old) && is_alive(old)) { open_window(sprintf("http://127.0.0.1:%d/", old)); quit(save = "no", status = 0) }
}

port <- httpuv::randomPort()
writeLines(as.character(port), state_file)
shiny::onStop(function() unlink(state_file))
message("3D Forest Height Studio: starting on port ", port, " (data in ", data_root, ")")
shiny::runApp(file.path(here, "app"), port = port, host = "127.0.0.1",
    launch.browser = function(url) open_window(url))
