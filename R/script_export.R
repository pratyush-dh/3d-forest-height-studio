#############################################
# Generate a standalone, path-free R script that reproduces the map
# currently shown in the viewer (region, tiles, layer, style, camera).
#############################################

# Pipeline functions are inlined from the real source (deparse), so the exported
# script never drifts from what the app actually runs.
script_functions <- function() {
    fns <- c("use_bundled_geodata", "with_planar", "get_admin1", "keep_mainland", "shift_antimeridian",
        "select_region", "wrap_lon", "tile_name", "tile_boxes", "tile_table", "local_laea", "get_canopy")
    one <- function(n) paste0(n, " <- ", paste(deparse(get(n, envir = globalenv()), width.cutoff = 100L), collapse = "\n"), "\n")
    paste(c(
        sprintf("ETH_BASE <- %s\n", paste(deparse(ETH_BASE), collapse = "")),
        vapply(fns, one, character(1)),
        "use_bundled_geodata()  # avoids PROJ/GDAL clashes with other installs (e.g. PostgreSQL/PostGIS); harmless otherwise\n"
    ), collapse = "\n")
}

rv <- function(x) paste(deparse(x, width.cutoff = 500L), collapse = " ") # R literal for a vector / string

# Camera -> rayshader angles. theta: 0 = looking from the south, + moves the camera east
# (verified against rayshader); phi: elevation above the horizon.
view_angles <- function(cam) {
    p <- unlist(cam$pos) - unlist(cam$target)
    list(phi = round(atan2(p[2], hypot(p[1], p[3])) * 180 / pi), theta = round(atan2(p[1], p[3]) * 180 / pi))
}
hypot <- function(a, b) sqrt(a^2 + b^2)

# cfg: list(country, regions, mainland, detail, project)
# st : viewer state from the browser (P, cls, camera, zmax)
make_script <- function(cfg, st, template_path) {
    P <- st$P; cl <- st$cls
    config <- paste(c(
        sprintf("country  <- %s     # ISO3 code (e.g. \"NPL\", \"PRT\", \"NZL\")", rv(cfg$country)),
        sprintf("regions  <- %s     # sub-regions to keep; character(0) = whole country", rv(as.character(cfg$regions))),
        sprintf("mainland <- %s     # drop remote islands / territories", rv(isTRUE(cfg$mainland))),
        sprintf("detail   <- %s     # raster size: cells along the longest side (higher = sharper, slower)", rv(as.integer(cfg$detail))),
        sprintf("project  <- %s     # reproject to a local equal-area CRS (recommended)", rv(isTRUE(cfg$project)))
    ), collapse = "\n")

    use_classes <- isTRUE(P$v_stepped)
    dec <- as.integer(P$v_legdec %||% 0)
    bounds <- as.numeric(unlist(cl$bounds)); colors <- as.character(unlist(cl$colors)); labs <- as.character(unlist(cl$labels))
    k <- length(colors)
    auto <- sprintf(paste0("%.", dec, "f-%.", dec, "f"), bounds[seq_len(k)], bounds[seq_len(k) + 1])
    labels <- ifelse(nzchar(labs[seq_len(k)]), labs[seq_len(k)], auto)
    ang <- view_angles(st$camera)
    style <- paste(c(
        "style <- list(",
        sprintf("    title = %s, subtitle = %s, legend_title = %s,", rv(P$v_title %||% ""), rv(P$v_subtitle %||% ""), rv(P$v_legtitle %||% "height (m)")),
        sprintf("    palette_name = %s,", rv(P$v_palette)),
        sprintf("    stops = %s,   # colour ramp used when use_classes = FALSE", rv(PALETTES[[P$v_palette]])),
        sprintf("    use_classes = %s,", rv(use_classes)),
        sprintf("    class_colors = %s,", rv(colors)),
        sprintf("    class_bounds = %s,   # metres", rv(bounds)),
        sprintf("    class_labels = %s,", rv(labels)),
        sprintf("    hmax = %s,   # heights above this are clipped in the colour scale", rv(as.numeric(P$v_hmax))),
        sprintf("    bg = %s,", rv(P$v_bg)),
        sprintf("    exaggeration = %s,", rv(as.numeric(P$v_exag))),
        sprintf("    sun_azimuth = %s, sun_altitude = %s, shadow = %s,", rv(as.numeric(P$v_sunaz)), rv(as.numeric(P$v_sunalt)), rv(as.numeric(P$v_shstrength))),
        sprintf("    phi = %s, theta = %s, zoom = 0.7   # camera (from the view you had when exporting)", ang$phi, ang$theta),
        ")"
    ), collapse = "\n")

    tpl <- paste(readLines(template_path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
    splice <- function(txt, marker, with) { # literal replacement (no regex / backslash handling)
        pos <- regexpr(marker, txt, fixed = TRUE)
        paste0(substr(txt, 1, pos - 1), with, substr(txt, pos + nchar(marker), nchar(txt)))
    }
    tpl <- splice(tpl, "{{DATE}}", format(Sys.Date(), "%Y-%m-%d"))
    tpl <- splice(tpl, "{{CONFIG}}", config)
    tpl <- splice(tpl, "{{STYLE}}", style)
    splice(tpl, "{{FUNCTIONS}}", script_functions())
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
