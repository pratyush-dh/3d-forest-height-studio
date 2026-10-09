#############################################
# 3D Forest Height Studio  (step-by-step)
#   1 Setup    load packages & libraries
#   2 Region   pick country / regions
#   3 Tiles    check disk, show sizes, download (with a game)
#   4 Build    crop + aggregate the canopy layer
#   5 Explore  live WebGL 3D playground + export
# Run:  shiny::runApp("app")
#############################################

for (p in c("shiny", "bslib")) {
    if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = "https://cloud.r-project.org")
}
library(shiny)
library(bslib)

app_dir <- normalizePath(".")
root_dir <- if (file.exists(file.path(app_dir, "R", "canopy_functions.R"))) app_dir else dirname(app_dir)
source(file.path(root_dir, "R", "canopy_functions.R"))
source(file.path(root_dir, "R", "script_export.R"))

cache_dir <- file.path(root_dir, "cache")
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
default_tile_dir <- file.path(root_dir, "data", "tiles")

PKGS <- c("sf", "terra", "geodata", "classInt", "jsonlite", "callr")
STEPS <- c("Setup", "Region", "Tiles", "Build", "Explore")

fmt_bytes <- function(b) {
    if (is.na(b)) return("unknown")
    if (b >= 1e9) sprintf("%.2f GB", b / 1e9) else sprintf("%.0f MB", b / 1e6)
}

free_space <- function(dir) {
    tryCatch({
        d <- normalizePath(dir, mustWork = FALSE)
        drive <- substr(d, 1, 1)
        out <- system2("powershell", c("-NoProfile", "-Command",
            shQuote(sprintf("(Get-PSDrive %s).Free", drive))), stdout = TRUE)
        as.numeric(out[1])
    }, error = function(e) NA_real_, warning = function(w) NA_real_)
}

cached_canopy <- function(iso3, regions, mainland, detail, project, poly, tile_dir, progress) {
    key <- paste("v2", iso3, paste(sort(regions), collapse = "|"), mainland, detail, project)
    kf <- tempfile(); writeLines(key, kf)
    path <- file.path(cache_dir, paste0("canopy_", iso3, "_", unname(tools::md5sum(kf)), ".tif"))
    if (file.exists(path)) return(terra::rast(path))
    r <- get_canopy(poly, detail, project, cache_dir, progress = progress, tile_dir = tile_dir)
    terra::writeRaster(r, path, overwrite = TRUE)
    r
}

# Light-weight map: region outline + the 3-degree tile grid it touches.
# status: NULL (plain preview) or per-tile list(ok = logical, nodata = logical) by tile name.
draw_preview <- function(bx, pl, ok = NULL, nodata = character()) {
    op <- par(mar = c(2.2, 4.2, 0.4, 0.4), bg = NA); on.exit(par(op))
    hit <- which(bx$hit)
    plot(sf::st_geometry(bx), border = if (nrow(bx) > 200) NA else "grey75", lty = 2, axes = TRUE,
        reset = FALSE, cex.axis = 0.75, las = 1)
    col <- vapply(bx$name[hit], function(nm) {
        if (nm %in% nodata) "#f4b6b0" else if (is.null(ok)) "#dcebe1" else
            if (isTRUE(ok[[nm]])) "#bfe3c9" else "#ffe2a8"
    }, character(1))
    plot(sf::st_geometry(bx[hit, ]), add = TRUE, col = col, border = "#4d6b5a", lwd = if (length(hit) > 150) 0.3 else 1)
    plot(sf::st_geometry(pl), add = TRUE, col = adjustcolor("#205544", 0.45), border = "#205544", lwd = 1)
    if (length(hit) <= 40) { # labels only when they stay readable
        ctr <- sf::st_coordinates(suppressWarnings(sf::st_centroid(sf::st_geometry(bx[hit, ]))))
        short <- sub("_Map.tif", "", sub("ETH_GlobalCanopyHeight_10m_2020_", "", bx$name[hit]))
        text(ctr[, 1], ctr[, 2], short, cex = 0.75, col = "#12332a", font = 2)
    }
    if (!is.null(ok)) legend("bottomright", bty = "n", cex = 0.75, pch = 15, pt.cex = 1.6,
        col = c("#bfe3c9", "#ffe2a8", "#f4b6b0"), legend = c("on disk", "to download", "no data"))
}

# ------------------------------------------------------------------ UI --
step_panel <- function(n, ...) conditionalPanel(sprintf("output.step == %d", n), ...)

ui <- page_fluid(
    theme = bs_theme(version = 5, bootswatch = "flatly", primary = "#205544"),
    tags$head(
        tags$title("3D Forest Height Studio"),
        tags$script(type = "importmap", HTML('{"imports":{
            "three":"https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js",
            "three/addons/":"https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/"}}')),
        tags$script(type = "module", src = "viewer.js"),
        tags$script(src = "runner.js", defer = NA),
        tags$script(src = "exporter.js"),
        tags$script(src = "studio.js", defer = NA),
        tags$style(HTML("
            body{background:#f6f8f7}
            .stepper{display:flex;gap:6px;margin:14px 0;flex-wrap:wrap}
            .stp{flex:1;min-width:110px;padding:8px 12px;border-radius:8px;background:#e6ece8;color:#6a7a70;font-weight:600;font-size:14px}
            .stp.done{background:#cfe4d6;color:#205544}
            .stp.now{background:#205544;color:#fff}
            .wrap{max-width:860px;margin:0 auto}
            .pkg{display:flex;justify-content:space-between;padding:6px 2px;border-bottom:1px solid #eee}
            .ok{color:#2a8a4a;font-weight:600}.bad{color:#c0392b;font-weight:600}.wait{color:#999}.run{color:#d68910;font-weight:600}
            table.tiles{width:100%;font-size:14px}
            .tilebox{max-height:240px;overflow-y:auto;border:1px solid #eee;border-radius:6px}
            table.tiles td,table.tiles th{padding:5px 8px;border-bottom:1px solid #eee}
            .progress-lg{height:18px}
            #runner{width:100%;max-width:640px;display:block;margin:10px auto 0;border-radius:8px;border:1px solid #cfe0d5;background:#f3f8f4;cursor:pointer}
            .stepper a.stp{text-decoration:none;display:block}
            .stepper a.stp.go{cursor:pointer}
            .stepper a.stp.go:hover{background:#b9d6c3}
            .topbar{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
            .preview{width:100%;height:300px;margin:6px 0}
            /* Explore: fixed-height two-column layout. Only the left column scrolls. */
            .explore{display:grid;grid-template-columns:350px minmax(0,1fr);gap:14px;height:calc(100vh - 225px);min-height:480px}
            .side{overflow-y:auto;overflow-x:hidden;padding-right:8px;background:transparent}
            .mapcol{display:flex;flex-direction:column;min-width:0;min-height:0;height:100%}
            .tabbar{display:flex;gap:4px;margin-bottom:6px}
            .tabbtn{border:1px solid #d5ddd8;background:#eef2ef;color:#4b5a52;padding:5px 14px;border-radius:8px 8px 0 0;font-weight:600;font-size:13px;cursor:pointer}
            .tabbtn.active{background:#205544;color:#fff;border-color:#205544}
            .mapbox{position:relative;overflow:hidden;border-radius:10px;border:1px solid #d5ddd8;background:#fff;min-width:0;flex:1;min-height:0}
            .codebox{display:none;flex-direction:column;flex:1;min-height:0;border-radius:10px;border:1px solid #1d3329;background:#0f1b16;overflow:hidden}
            .codebar{display:flex;gap:8px;align-items:center;padding:8px 10px;background:#162720;border-bottom:1px solid #1d3329;color:#a9c4b4;font-size:12px;flex-wrap:wrap}
            .codebar .btn{font-size:12px;padding:2px 10px}
            #code-view{flex:1;margin:0;overflow:auto;padding:12px 14px;font-size:12px;line-height:1.45;color:#dbeee3;white-space:pre;tab-size:4}
            #locator{position:absolute;right:12px;top:12px;display:none}
            #mapinfo{position:absolute;left:12px;bottom:26px;background:rgba(255,255,255,.82);padding:6px 9px;border-radius:5px;font-size:11px;line-height:1.45;color:#333;max-width:72%;pointer-events:none;display:none}
            .credits{max-width:1400px;margin:10px auto 6px;font-size:11px;color:#6b7a72;text-align:center}
            .credits a{color:#205544}
            #viewer{position:absolute;inset:0;overflow:hidden}
            #viewer canvas{display:block;width:100%;height:100%}
            #viewer-empty{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#888;pointer-events:none}
            #maptitle{position:absolute;top:12px;pointer-events:none;max-width:85%;display:none}
            .mt-t{font-weight:700;line-height:1.25}
            .mt-s{font-size:.6em;opacity:.75;margin-top:2px}
            #embed-snippet{font-family:ui-monospace,Consolas,monospace;font-size:11px}
            #legend{position:absolute;background:rgba(255,255,255,.85);padding:8px 10px;border-radius:6px;color:#222;pointer-events:none;display:none}
            .lg-title{font-weight:600;margin-bottom:4px}
            .lg-row{display:flex;align-items:center;gap:6px;line-height:1.5}
            .lg-sw{width:1.3em;height:1.3em;display:inline-block}
            .lg-grad{display:flex;gap:6px}
            .lg-bar{width:1.3em;height:10em;display:inline-block}
            .lg-lab{display:flex;flex-direction:column;justify-content:space-between;font-weight:400}
            #hint{margin-left:auto;align-self:center;font-size:12px;color:#777;white-space:nowrap}
            #class-editor{margin:4px 0 10px}
            .ce-head,.ce-row{display:grid;grid-template-columns:34px 38px 64px 1fr;gap:6px;align-items:center;margin-bottom:4px}
            .ce-head{font-size:11px;color:#777}
            .ce-row input[type=color]{width:34px;height:28px;padding:0;border:1px solid #ccc;border-radius:4px;background:none}
            .ce-row input[type=number],.ce-row input[type=text]{width:100%;font-size:12px;padding:2px 5px;border:1px solid #ccc;border-radius:4px}
            .ce-lo{font-size:12px;color:#555;text-align:right}
        "))
    ),
    div(class = "topbar mt-3", h3("3D Forest Height Studio", class = "mb-0"), uiOutput("nav")),
    uiOutput("stepper"),

    # ---- 1 Setup
    step_panel(1, div(class = "wrap", card(
        card_header("Step 1 · Loading packages & libraries"),
        uiOutput("pkg_list"),
        uiOutput("pkg_msg")
    ))),

    # ---- 2 Region
    step_panel(2, div(class = "wrap", card(
        card_header("Step 2 · Choose a country or region"),
        selectizeInput("country", "Country", choices = NULL, width = "100%"),
        selectizeInput("regions", "Sub-regions (blank = whole country)", choices = NULL, multiple = TRUE, width = "100%"),
        layout_columns(
            checkboxInput("mainland", "Mainland only (drop remote islands)", TRUE),
            checkboxInput("project", "Reproject to local equal-area CRS", TRUE)
        ),
        sliderInput("detail", "Detail (cells on the longest side)", 200, 1200, 500, step = 50, width = "100%"),
        div(class = "small text-muted", "Preview: region outline and the 3° tiles it touches"),
        plotOutput("region_map", height = "300px"),
        actionButton("find_tiles", "Find required tiles →", class = "btn-primary")
    ))),

    # ---- 3 Tiles
    step_panel(3, div(class = "wrap", card(
        card_header("Step 3 · Canopy-height tiles (ETH Zurich, 10 m, 3° × 3°)"),
        layout_columns(col_widths = c(8, 4),
            textInput("tile_dir", "Save / look for tiles in this folder", default_tile_dir, width = "100%"),
            div(style = "margin-top:32px", actionButton("browse", "Browse…"),
                actionButton("recheck", "Re-check"))),
        uiOutput("tile_summary"),
        plotOutput("tile_map", height = "300px"),
        uiOutput("tile_table"),
        uiOutput("dl_progress"),
        uiOutput("tile_actions")
    ))),

    # ---- 4 Build
    step_panel(4, div(class = "wrap", card(
        card_header("Step 4 · Build the canopy layer"),
        p("This crops every tile to your region, averages it down to the chosen detail, masks to the border and (optionally) reprojects. It can take a minute or two."),
        uiOutput("build_info"),
        uiOutput("built_note"),
        actionButton("build", "Run the engine ▶", class = "btn-primary")
    ))),

    # ---- game (shown while downloading or building)
    conditionalPanel("output.show_game == 1", div(class = "wrap",
        div(class = "text-center text-muted small mt-2", "While you wait: Canopy Runner (Space / tap to jump)"),
        tags$canvas(id = "runner", width = 640, height = 160, tabindex = 0))),

    # ---- 5 Explore
    step_panel(5, div(class = "explore",
        div(class = "side",
            accordion(
                open = TRUE, multiple = TRUE,
                accordion_panel("View & light",
                    div(class = "btn-group w-100 mb-3",
                        tags$button(id = "view-oblique", class = "btn btn-outline-secondary btn-sm", "Oblique"),
                        tags$button(id = "view-top", class = "btn btn-outline-secondary btn-sm", "Top"),
                        tags$button(id = "view-side", class = "btn btn-outline-secondary btn-sm", "Side")),
                    sliderInput("v_exag", "Height exaggeration", 0.1, 5, 1, step = 0.1),
                    sliderInput("v_fov", "Field of view", 15, 90, 40),
                    sliderInput("v_sunaz", "Sun azimuth", 0, 360, 315),
                    sliderInput("v_sunalt", "Sun altitude", 3, 90, 35),
                    checkboxInput("v_shadows", "Cast shadows", TRUE),
                    sliderInput("v_shstrength", "Shadow strength", 0, 1, 0.6, step = 0.05),
                    checkboxInput("v_rotate", "Auto-rotate", FALSE)),
                accordion_panel("Colours",
                    selectInput("v_palette", "Palette", names(PALETTES)),
                    checkboxInput("v_stepped", "Discrete classes (edit each one)", FALSE),
                    sliderInput("v_classes", "Number of classes", 2, 10, 5, step = 1),
                    div(id = "class-editor"),
                    sliderInput("v_hmax", "Clip heights above (m)", 5, 100, 100, step = 1),
                    selectInput("v_bg", "Background",
                        c(White = "#ffffff", Cream = "#f7f1e3", Grey = "#cfd3d6", Black = "#111111")),
                    checkboxInput("v_ground", "Ground plane", TRUE)),
                accordion_panel("Grid, scale & context",
                    checkboxInput("v_grid", "Lat/long grid under the map", TRUE),
                    checkboxInput("v_gridlabels", "Grid labels", TRUE),
                    sliderInput("v_gridop", "Grid opacity", 0.05, 0.9, 0.3, step = 0.05),
                    checkboxInput("v_scalebar", "Scale bar", TRUE),
                    checkboxInput("v_locator", "Globe locator with extent", TRUE),
                    checkboxInput("v_info", "CRS and scale box", TRUE),
                    checkboxInput("v_credits", "Credits line", TRUE)),
                accordion_panel("Title",
                    checkboxInput("v_titleshow", "Show title", TRUE),
                    textInput("v_title", "Title", ""),
                    textInput("v_subtitle", "Subtitle (optional)", ""),
                    selectInput("v_titlealign", "Alignment", c("Left" = "left", "Centre" = "center")),
                    sliderInput("v_titlesize", "Size", 0.6, 2.5, 1, step = 0.1)),
                accordion_panel("Legend",
                    checkboxInput("v_legshow", "Show legend", TRUE),
                    textInput("v_legtitle", "Title", "height (m)"),
                    selectInput("v_legpos", "Position",
                        c("Bottom right" = "br", "Bottom left" = "bl", "Top right" = "tr", "Top left" = "tl")),
                    sliderInput("v_legsize", "Size", 0.6, 2, 1, step = 0.1),
                    selectInput("v_legdec", "Decimals in labels", c("0" = 0, "1" = 1, "2" = 2))),
                accordion_panel("Export",
                    selectInput("snap_scale", "PNG resolution", c("1× (as shown)" = 1, "2×" = 2, "4×" = 4)),
                    tags$button(id = "snap", class = "btn btn-success w-100 mb-2", "Save this view as PNG"),
                    downloadButton("dl_tif", "Download layer (GeoTIFF)", class = "w-100"),
                    hr(),
                    strong("Share as a web page"),
                    p(class = "small text-muted mb-2", "One self-contained interactive HTML file with your current view, colours, title and legend. No R needed to open it."),
                    checkboxInput("embed_controls", "Include a small control panel for viewers", TRUE),
                    checkboxInput("embed_bundle", "Bundle 3D engine (works offline, +1.3 MB)", TRUE),
                    tags$button(id = "embed-go", class = "btn btn-primary w-100 mb-1", "Download interactive HTML"),
                    div(id = "embed-note", class = "small text-muted mb-2"),
                    tags$label(class = "small", `for` = "embed-snippet", "Embed code (after you host the file)"),
                    tags$textarea(id = "embed-snippet", class = "form-control", rows = 3, readonly = NA,
                        placeholder = "Appears after you export"),
                    tags$button(id = "embed-copy", class = "btn btn-outline-secondary btn-sm mt-1", "Copy embed code"),
                    p(class = "small text-muted mt-2", "Host it anywhere static (GitHub Pages, Netlify Drop, your own site) and paste the <iframe> into your page."))
            )),
        div(class = "mapcol",
            div(class = "tabbar",
                tags$button(id = "tab-map", class = "tabbtn active", "3D map"),
                tags$button(id = "tab-code", class = "tabbtn", "R code"),
                div(id = "hint", "drag: orbit · right-drag: pan · wheel: zoom · ", textOutput("status", inline = TRUE))),
            div(class = "mapbox", id = "pane-map",
                div(id = "viewer"),
                div(id = "viewer-empty", "Layer not loaded yet"),
                div(id = "maptitle"),
                tags$canvas(id = "locator"),
                div(id = "legend"),
                div(id = "mapinfo")),
            div(class = "codebox", id = "pane-code",
                div(class = "codebar",
                    span(id = "code-info", "Standalone R script that reproduces this map (no machine-specific paths)."),
                    tags$button(id = "code-refresh", class = "btn btn-outline-light", "Refresh from current view"),
                    tags$button(id = "code-copy", class = "btn btn-outline-light", "Copy"),
                    tags$button(id = "code-dl", class = "btn btn-success", "Download .R")),
                tags$pre(id = "code-view", "Open this tab after building a layer to generate the script.")))
    )),
    div(class = "credits",
        "Visualisation concept & original R tutorial: ",
        tags$a(href = "https://github.com/milos-agathon/3d-forest-height-maps", target = "_blank", "Milos Popovic (milos-agathon/3d-forest-height-maps)"),
        " · Canopy height: ETH Zurich Global Canopy Height 2020 (Lang et al., 2023, Nature Ecology & Evolution) · Boundaries: GADM 4.1")
)

# -------------------------------------------------------------- server --
server <- function(input, output, session) {
    step <- reactiveVal(1)
    output$step <- renderText(step())
    outputOptions(output, "step", suspendWhenHidden = FALSE)

    admin1 <- reactiveVal(NULL)
    poly <- reactiveVal(NULL)
    tiles <- reactiveVal(NULL)
    tick <- reactiveVal(0)
    dl <- reactiveVal(NULL)
    canopy <- reactiveVal(NULL)
    status <- reactiveVal("")
    title <- reactiveVal("")
    boxes <- reactiveVal(NULL)
    max_step <- reactiveVal(1)
    size_jobs <- reactiveVal(list())
    output$status <- renderText(status())
    output$title <- renderText(title())

    output$show_game <- renderText(as.integer(!is.null(dl()) || (step() == 4)))
    outputOptions(output, "show_game", suspendWhenHidden = FALSE)

    # Every reached step stays reachable: click the stepper, or use Back / Next.
    output$stepper <- renderUI(div(class = "stepper", lapply(seq_along(STEPS), function(i) {
        cls <- if (i < step()) "stp done" else if (i == step()) "stp now" else "stp"
        lab <- sprintf("%d · %s", i, STEPS[i])
        if (i >= 2 && i <= max_step() && i != step())
            tags$a(class = paste(cls, "go"), href = "#", lab,
                onclick = sprintf("Shiny.setInputValue('goto', %d, {priority: 'event'}); return false;", i))
        else div(class = cls, lab)
    })))
    output$nav <- renderUI(div(class = "d-flex gap-2",
        if (step() > 2) actionButton("nav_back", "← Back", class = "btn-outline-secondary btn-sm"),
        if (step() >= 2 && step() < max_step()) actionButton("nav_next", "Next →", class = "btn-outline-primary btn-sm")))
    observeEvent(input$goto, {
        g <- as.integer(input$goto); if (g >= 2 && g <= max_step()) step(g); tick(tick() + 1)
    })
    observeEvent(input$nav_back, step(max(2, step() - 1)))
    observeEvent(input$nav_next, step(min(max_step(), step() + 1)))

    # ---- 1 setup: load one package per flush so progress is visible
    pkg_status <- reactiveVal(setNames(rep("wait", length(PKGS)), PKGS))
    pkg_idx <- reactiveVal(1)
    observe({
        req(step() == 1)
        invalidateLater(150)
        isolate({
            i <- pkg_idx(); st <- pkg_status()
            if (i > length(PKGS)) {
                if (all(st == "ok")) {
                    updateSelectizeInput(session, "country",
                        choices = c("Select a country..." = "", country_choices()))
                    step(2)
                }
                return()
            }
            p <- PKGS[i]
            if (requireNamespace(p, quietly = TRUE)) {
                suppressMessages(library(p, character.only = TRUE))
                st[p] <- "ok"; pkg_idx(i + 1)
            } else if (st[p] != "run") {
                st[p] <- "run"
            } else {
                try(install.packages(p, repos = "https://cloud.r-project.org"), silent = TRUE)
                ok <- requireNamespace(p, quietly = TRUE)
                st[p] <- if (ok) "ok" else "failed"
                pkg_idx(if (ok) i + 1 else Inf)
            }
            pkg_status(st)
        })
    })
    output$pkg_list <- renderUI(lapply(PKGS, function(p) {
        s <- pkg_status()[[p]]
        lab <- c(wait = "waiting", run = "installing…", ok = "✓ loaded", failed = "✗ failed")[[s]]
        div(class = "pkg", span(p), span(class = switch(s, ok = "ok", failed = "bad", run = "run", "wait"), lab))
    }))
    output$pkg_msg <- renderUI(if (any(pkg_status() == "failed"))
        div(class = "bad mt-2", "A package could not be installed. Install it manually in R, then reload this page."))

    # ---- 2 region
    observeEvent(input$country, {
        req(input$country)
        withProgress(message = "Fetching administrative boundaries", {
            a <- tryCatch(get_admin1(input$country, cache_dir), error = function(e) {
                showNotification(paste("Boundary download failed:", conditionMessage(e)), type = "error"); NULL
            })
        })
        admin1(a)
        if (!is.null(a)) updateSelectizeInput(session, "regions", choices = sort(unique(a$NAME_1)), selected = character(0))
    }, ignoreInit = TRUE)

    sel_poly_raw <- reactive({
        req(admin1(), input$country)
        withProgress(message = "Preparing region outline", value = 0.5,
            tryCatch(select_region(admin1(), input$regions, input$mainland), error = function(e) NULL))
    })
    sel_poly <- debounce(sel_poly_raw, 400)
    output$region_map <- renderPlot({
        pl <- sel_poly(); req(pl)
        draw_preview(tile_boxes(pl), pl)
    }, res = 96)

    observeEvent(input$find_tiles, {
        pl <- sel_poly(); req(pl)
        bx <- tile_boxes(pl)
        tt <- bx[bx$hit, ]
        tt <- data.frame(name = tt$name, url = tt$url, remote = NA_real_, stringsAsFactors = FALSE)
        if (nrow(tt) == 0) return(showNotification("No canopy-height tiles cover this region.", type = "error"))
        bx$nodata <- FALSE
        poly(pl); boxes(bx); tiles(tt); tick(tick() + 1)
        # tile sizes are looked up in background processes, so the UI never waits on the network
        n <- min(6, nrow(tt)); grp <- rep_len(seq_len(n), nrow(tt))
        size_jobs(lapply(seq_len(n), function(k) list(
            idx = which(grp == k),
            job = callr::r_bg(fetch_sizes, args = list(tt$url[grp == k]), supervise = TRUE))))
        max_step(3); step(3) # a new region invalidates any earlier build
    })
    observe({ # collect size lookups as they finish
        jobs <- size_jobs(); req(length(jobs) > 0); invalidateLater(500)
        isolate({
            tt <- tiles(); changed <- FALSE
            for (k in seq_along(jobs)) {
                j <- jobs[[k]]
                if (!is.null(j$job) && !j$job$is_alive()) {
                    res <- tryCatch(j$job$get_result(), error = function(e) rep(NA_real_, length(j$idx)))
                    tt$remote[j$idx] <- res; jobs[[k]]$job <- NULL; changed <- TRUE
                }
            }
            if (!changed) return()
            if (all(vapply(jobs, function(j) is.null(j$job), logical(1)))) {
                gone <- !is.na(tt$remote) & tt$remote == 0 # 404: no data (open ocean etc.)
                bx <- boxes(); bx$nodata <- bx$name %in% tt$name[gone]; boxes(bx)
                tt <- tt[!gone, , drop = FALSE]
                size_jobs(list())
                if (nrow(tt) == 0) { showNotification("No canopy-height data exists for this region.", type = "error"); step(2) }
            } else size_jobs(jobs)
            tiles(tt); tick(tick() + 1)
        })
    })

    # ---- 3 tiles
    observeEvent(input$browse, {
        d <- tryCatch(utils::choose.dir(default = input$tile_dir, caption = "Folder for ETH canopy-height tiles"),
            error = function(e) NA)
        if (!is.na(d)) updateTextInput(session, "tile_dir", value = normalizePath(d, winslash = "/"))
    })
    observeEvent(input$recheck, tick(tick() + 1))

    tstate <- reactive({
        tick(); tt <- tiles(); req(tt, nzchar(input$tile_dir))
        f <- file.path(input$tile_dir, tt$name)
        sz <- ifelse(file.exists(f), file.size(f), 0)
        pt <- paste0(f, ".part")
        ps <- ifelse(file.exists(pt), file.size(pt), 0)
        cbind(tt, path = f, local = sz, part = ps,
            ok = sz > 0 & (is.na(tt$remote) | sz >= tt$remote), stringsAsFactors = FALSE)
    })

    output$tile_map <- renderPlot({
        ts <- tstate(); bx <- boxes(); req(bx, poly())
        draw_preview(bx, poly(), ok = setNames(as.list(ts$ok), ts$name), nodata = bx$name[bx$nodata])
    }, res = 96)

    output$tile_summary <- renderUI({
        ts <- tstate()
        todo <- ts[!ts$ok, ]
        need <- sum(ifelse(is.na(todo$remote), 250e6, todo$remote))
        free <- free_space(input$tile_dir)
        checking <- length(size_jobs()) > 0
        tagList(
            p(HTML(sprintf(
                "<b>%d</b> tiles cover your region (%s in total). <b>%d</b> already on disk, <b>%d</b> to download → <b>%s</b>.",
                nrow(ts), fmt_bytes(sum(ts$remote, na.rm = TRUE)), sum(ts$ok), nrow(todo), fmt_bytes(need)))),
            if (checking) p(class = "run", "Checking tile sizes on the server… (you can wait here, nothing is frozen)"),
            if (!checking && nrow(todo) > 30) p(class = "bad", sprintf(
                "That is a very large download (%d tiles). Consider fewer sub-regions, or a lower-detail country subset.", nrow(todo))),
            if (!is.na(free)) p(class = if (free < need * 1.1) "bad" else "text-muted",
                sprintf("Free space on that drive: %s%s", fmt_bytes(free),
                    if (free < need * 1.1) " — not enough, pick another folder" else ""))
        )
    })
    output$tile_table <- renderUI({
        ts <- tstate(); busy <- !is.null(dl())
        rows <- lapply(seq_len(nrow(ts)), function(i) {
            r <- ts[i, ]
            st <- if (r$ok) span(class = "ok", "✓ on disk") else if (busy && r$part > 0)
                span(class = "run", sprintf("downloading %s", fmt_bytes(r$part))) else span(class = "wait", "to download")
            tags$tr(tags$td(sub("ETH_GlobalCanopyHeight_10m_2020_", "", sub("_Map.tif", "", r$name))),
                tags$td(fmt_bytes(r$remote)), tags$td(st))
        })
        div(class = "tilebox", tags$table(class = "tiles", tags$tr(tags$th("Tile"), tags$th("Size"), tags$th("Status")), rows))
    })
    output$dl_progress <- renderUI({
        req(dl()); ts <- tstate(); todo <- ts[!ts$ok, ]
        tot <- sum(ifelse(is.na(todo$remote), 250e6, todo$remote))
        got <- sum(pmin(todo$part, ifelse(is.na(todo$remote), Inf, todo$remote)))
        pct <- if (tot > 0) round(100 * got / tot) else 0
        div(class = "mt-3",
            div(class = "progress progress-lg", div(class = "progress-bar progress-bar-striped progress-bar-animated",
                style = sprintf("width:%d%%", pct), sprintf("%d%%", pct))),
            div(class = "small text-muted mt-1", sprintf("%s of %s", fmt_bytes(got), fmt_bytes(tot))))
    })
    output$tile_actions <- renderUI({
        ts <- tstate(); missing <- sum(!ts$ok)
        if (length(size_jobs()) > 0) return(div(class = "mt-3 text-muted", "Waiting for tile sizes…"))
        div(class = "mt-3 d-flex gap-2 flex-wrap",
            if (!is.null(dl())) actionButton("cancel_dl", "Cancel download", class = "btn-outline-danger")
            else if (missing > 0) tagList(
                actionButton("start_dl", sprintf("Download %d missing tile%s", missing, if (missing > 1) "s" else ""),
                    class = "btn-primary"),
                actionButton("stream", "Skip download — stream just my area (slower)", class = "btn-outline-secondary"))
            else actionButton("to_build", "Tiles ready → continue", class = "btn-success"))
    })

    observeEvent(input$start_dl, {
        ts <- tstate(); todo <- ts[!ts$ok, ]
        dir.create(input$tile_dir, recursive = TRUE, showWarnings = FALSE)
        if (!dir.exists(input$tile_dir)) return(showNotification("Cannot create that folder.", type = "error"))
        dl(callr::r_bg(download_tiles, args = list(todo$url, todo$path), supervise = TRUE))
    })
    observeEvent(input$cancel_dl, {
        try(dl()$kill(), silent = TRUE); dl(NULL); tick(tick() + 1)
    })
    observe({ # poll the background download
        req(dl()); invalidateLater(700)
        isolate({
            tick(tick() + 1)
            if (!dl()$is_alive()) {
                ok <- tryCatch({ dl()$get_result(); TRUE }, error = function(e) {
                    showNotification(paste("Download problem:", conditionMessage(e)), type = "error"); FALSE })
                dl(NULL); tick(tick() + 1)
                if (ok) showNotification("All tiles downloaded.", type = "message")
            }
        })
    })
    session$onSessionEnded(function() isolate(try(if (!is.null(dl())) dl()$kill(), silent = TRUE)))

    go_build <- function() { max_step(max(max_step(), 4)); step(4) }
    observeEvent(input$to_build, go_build())
    observeEvent(input$stream, go_build())

    # ---- 4 build
    output$build_info <- renderUI({
        ts <- tryCatch(tstate(), error = function(e) NULL); req(ts)
        p(class = "text-muted", sprintf("%d of %d tiles are local; %s", sum(ts$ok), nrow(ts),
            if (all(ts$ok)) "everything will be read from disk." else "the rest will be streamed from the server."))
    })
    output$built_note <- renderUI(if (!is.null(canopy()) && max_step() >= 5)
        div(class = "alert alert-success py-2", "A layer is already built for this region. Use Next → to open it, or re-run to rebuild."))
    observeEvent(input$build, {
        req(poly())
        nm <- names(country_choices())[country_choices() == input$country]
        ttl <- if (length(input$regions)) paste(nm, "–", paste(input$regions, collapse = ", ")) else nm
        withProgress(message = "Running the engine", value = 0, {
            r <- tryCatch(withCallingHandlers(
                cached_canopy(input$country, input$regions, input$mainland, input$detail, input$project,
                    poly(), input$tile_dir, function(v, m) setProgress(v, detail = m)),
                warning = function(w) {
                    showNotification(conditionMessage(w), type = "warning", duration = NULL)
                    invokeRestart("muffleWarning")
                }),
                error = function(e) { showNotification(paste("Build failed:", conditionMessage(e)), type = "error"); NULL })
        })
        req(r)
        canopy(r)
        m <- terra::as.matrix(r, wide = TRUE)
        q <- ifelse(is.na(m), 255, pmin(254, round(m * 2))) # 0.5 m steps, 255 = no data
        session$sendCustomMessage("canopy", list(
            nrow = nrow(m), ncol = ncol(m),
            data = jsonlite::base64_enc(as.raw(as.vector(t(q)))),
            zmax = max(m, na.rm = TRUE), title = ttl, palettes = lapply(PALETTES, as.list),
            geo = tryCatch(make_geo(r, poly(), cache_dir), error = function(e) {
                showNotification(paste("Grid / locator unavailable:", conditionMessage(e)), type = "warning"); NULL })))
        title(ttl)
        updateTextInput(session, "v_title", value = ttl)
        status(sprintf("%d × %d cells · tallest canopy %.0f m", ncol(m), nrow(m), max(m, na.rm = TRUE)))
        max_step(5); step(5)
    })

    # ---- 5 R code tab: reproduce the current map outside the app
    observeEvent(input$viewer_state, {
        st <- tryCatch(jsonlite::fromJSON(input$viewer_state, simplifyVector = TRUE), error = function(e) NULL)
        req(st, input$country)
        cfg <- list(country = input$country, regions = input$regions, mainland = input$mainland,
            detail = input$detail, project = input$project)
        txt <- tryCatch(make_script(cfg, st, file.path(app_dir, "templates", "replicate_template.R")),
            error = function(e) { showNotification(paste("Could not build the script:", conditionMessage(e)), type = "error"); NULL })
        req(txt)
        session$sendCustomMessage("code", list(text = txt, name = paste0(input$country, "-forest-3d.R")))
    })

    # ---- 5 export
    output$dl_tif <- downloadHandler(
        filename = function() paste0(gsub("[^A-Za-z0-9]+", "-", title()), "-canopy-height.tif"),
        content = function(file) terra::writeRaster(canopy(), file, overwrite = TRUE)
    )
}

shinyApp(ui, server)
