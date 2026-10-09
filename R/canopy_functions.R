#############################################
# Reusable pipeline for 3D forest height maps: any country / admin-1 regions on request.
# Inspired by Milos Popovic's tutorial on 3D forest-height maps with R:
#   https://github.com/milos-agathon/3d-forest-height-maps
#   https://www.youtube.com/watch?v=4ScYWPMzy6E
#############################################

# Same host as R/main.r (the older share.phys.ethz.ch path now redirects to a DOI page)
# Installers such as PostgreSQL/PostGIS set machine-wide PROJ_LIB / GDAL_DATA that point at
# their own (often older) databases, which makes terra/sf print "proj.db contains
# DATABASE.LAYOUT.VERSION.MINOR..." errors. Use the data bundled with the R packages
# instead, for this R process only (child processes inherit it). Must run before sf/terra load.
use_bundled_geodata <- function() {
    for (pkg in c("sf", "terra")) {
        base <- system.file(package = pkg)
        if (nzchar(base) && file.exists(file.path(base, "proj", "proj.db"))) {
            Sys.setenv(PROJ_LIB = file.path(base, "proj"), PROJ_DATA = file.path(base, "proj"))
            if (dir.exists(file.path(base, "gdal"))) Sys.setenv(GDAL_DATA = file.path(base, "gdal"))
            return(invisible(pkg))
        }
    }
    invisible(NULL)
}
use_bundled_geodata()

ETH_BASE <- paste0(
    "https://libdrive.ethz.ch/index.php/s/cO8or7iOe5dT2Rt/download",
    "?path=%2F3deg_cogs&files="
)

PALETTES <- list(
    "Forest (original)" = c("white", "#ffd3af", "#fbe06e", "#6daa55", "#205544"),
    "Viridis"           = c("#fde725", "#5ec962", "#21918c", "#3b528b", "#440154"),
    "Magma"             = c("#fcfdbf", "#fc8961", "#b73779", "#51127c", "#000004"),
    "Ocean to canopy"   = c("#f7fbff", "#9ecae1", "#41ab5d", "#006d2c", "#00441b"),
    "Autumn"            = c("white", "#fee08b", "#f46d43", "#a50026", "#4d0013")
)

# ---- 1. REGIONS ---------------------------------------------------------

country_choices <- function() {
    cc <- geodata::country_codes()
    cc <- cc[!is.na(cc$ISO3) & nzchar(cc$ISO3), ]
    stats::setNames(cc$ISO3, cc$NAME)[order(cc$NAME)]
}

# GADM admin-1 (falls back to admin-0 where a country has no level 1)
get_admin1 <- function(iso3, cache_dir) {
    out <- tryCatch(
        geodata::gadm(iso3, level = 1, path = cache_dir),
        error = function(e) NULL
    )
    if (is.null(out)) {
        out <- geodata::gadm(iso3, level = 0, path = cache_dir)
        out$NAME_1 <- out$COUNTRY
    }
    sf::st_as_sf(out)
}

# Run an sf operation in planar (GEOS) mode; s2 is off for lon/lat that may exceed 180.
with_planar <- function(expr) {
    old <- suppressMessages(sf::sf_use_s2(FALSE))
    on.exit(suppressMessages(sf::sf_use_s2(old)))
    suppressMessages(expr)
}

# Keep only the main landmass cluster (drops far-flung islands/territories).
# Adjacent admin regions are merged into real landmasses FIRST; otherwise a
# region far from the single largest region (e.g. eastern Nepal) is wrongly dropped.
# Planar throughout (no s2): simplified boundaries are not always valid on the sphere,
# and the geometry may already be in the shifted 0..360 frame.
keep_mainland <- function(geom, dist_km = 300) {
    crs <- sf::st_crs(geom)
    flat <- sf::st_set_crs(sf::st_sfc(sf::st_union(geom)), NA)
    parts <- suppressWarnings(sf::st_cast(sf::st_sf(geometry = flat), "POLYGON"))
    if (nrow(parts) < 2) return(sf::st_set_crs(sf::st_union(parts), crs))
    lat <- sf::st_coordinates(sf::st_centroid(sf::st_geometry(parts)))[, 2]
    area <- as.numeric(sf::st_area(parts)) * cos(lat * pi / 180) # deg^2 weighted to ~true area
    biggest <- parts[which.max(area), ]
    d <- dist_km / (111 * max(cos(mean(lat) * pi / 180), 0.3)) # km -> degrees (generous at high lat)
    near <- lengths(sf::st_is_within_distance(parts, biggest, dist = d)) > 0
    sf::st_set_crs(sf::st_union(parts[near, ]), crs)
}

# Regions spanning +-180 (Fiji, Russia, Alaska/Aleutians...) are moved to 0..360
# so the region is one contiguous box instead of a 360-degree-wide one.
shift_antimeridian <- function(geom) {
    bb <- sf::st_bbox(geom)
    if (bb[["xmax"]] - bb[["xmin"]] <= 180) return(geom)
    sh <- with_planar(sf::st_shift_longitude(geom))
    bs <- sf::st_bbox(sh)
    if ((bs[["xmax"]] - bs[["xmin"]]) < (bb[["xmax"]] - bb[["xmin"]]) - 90) sh else geom
}

# Boundaries are simplified in proportion to the region's size (about span/3000,
# i.e. well below the output cell size). Full GADM coastlines run to millions of
# vertices, which made union/distance/intersect take minutes for e.g. Chile or NZ.
select_region <- function(admin1, regions = NULL, mainland = TRUE) {
    if (!is.null(regions) && length(regions) > 0) {
        admin1 <- admin1[admin1$NAME_1 %in% regions, ]
    }
    if (nrow(admin1) == 0) stop("No regions selected.")
    v <- terra::vect(sf::st_geometry(admin1))
    e <- as.vector(terra::ext(v))
    span <- min(max(e[2] - e[1], e[4] - e[3]), 60)
    tol <- min(0.01, max(0.0005, span / 3000))
    v <- terra::aggregate(terra::simplifyGeom(v, tolerance = tol, preserveTopology = TRUE))
    geom <- sf::st_geometry(sf::st_as_sf(v))
    geom <- with_planar(sf::st_make_valid(geom))
    geom <- with_planar(shift_antimeridian(sf::st_union(geom))) # contiguous frame first, so island distances are real
    if (mainland) with_planar(keep_mainland(geom)) else geom
}

# ---- 2. ETH TILES -------------------------------------------------------

wrap_lon <- function(lon) ((lon + 180) %% 360) - 180

# 3-degree tiles are named by their SW corner, e.g. N39W009 covers 39-42N, 9-6W
tile_name <- function(lat, lon) {
    lon <- wrap_lon(lon)
    sprintf(
        "ETH_GlobalCanopyHeight_10m_2020_%s%02d%s%03d_Map.tif",
        ifelse(lat >= 0, "N", "S"), abs(lat),
        ifelse(lon >= 0, "E", "W"), abs(lon)
    )
}

# Every 3-degree cell inside the region's bounding box, flagged by whether it
# actually intersects the region. Used both for the download list and the map preview.
# `shift` is 360 for cells in the shifted (0..360) frame that sit east of 180.
tile_boxes <- function(poly_sf) {
    bb <- sf::st_bbox(poly_sf)
    g <- expand.grid(
        lat = seq(floor(bb[["ymin"]] / 3) * 3, floor(bb[["ymax"]] / 3) * 3, by = 3),
        lon = seq(floor(bb[["xmin"]] / 3) * 3, floor(bb[["xmax"]] / 3) * 3, by = 3)
    )
    geom <- sf::st_sfc(lapply(seq_len(nrow(g)), function(i) {
        sf::st_polygon(list(rbind(
            c(g$lon[i], g$lat[i]), c(g$lon[i] + 3, g$lat[i]), c(g$lon[i] + 3, g$lat[i] + 3),
            c(g$lon[i], g$lat[i] + 3), c(g$lon[i], g$lat[i])
        )))
    }), crs = sf::st_crs(poly_sf))
    hit <- with_planar(lengths(sf::st_intersects(geom, sf::st_union(poly_sf))) > 0)
    out <- sf::st_sf(
        name = tile_name(g$lat, g$lon), lat = g$lat, lon = g$lon,
        shift = g$lon - wrap_lon(g$lon), hit = hit, geometry = geom
    )
    out$url <- paste0(ETH_BASE, out$name)
    out
}

# Tiles that actually intersect the region (not just its bounding box)
tile_table <- function(poly_sf) {
    bx <- tile_boxes(poly_sf)
    bx <- bx[bx$hit, ]
    data.frame(name = bx$name, url = bx$url, shift = bx$shift, stringsAsFactors = FALSE)
}

# Remote sizes in bytes. NA = unknown (kept), 0 = tile does not exist (404, e.g. open ocean).
# Self-contained so it can run in a background R process; each request has a timeout.
fetch_sizes <- function(urls, timeout = 20) {
    one <- function(u) {
        for (attempt in 1:2) {
            h <- tryCatch(curlGetHeaders(u, timeout = timeout), error = function(e) NULL)
            if (is.null(h)) next
            st <- attr(h, "status")
            if (st == 404) return(0)
            if (st == 200) {
                cl <- grep("^content-length:", h, value = TRUE, ignore.case = TRUE)
                return(if (length(cl)) as.numeric(sub("[^0-9]*([0-9]+).*", "\\1", cl[length(cl)])) else NA_real_)
            }
        }
        NA_real_
    }
    vapply(urls, one, numeric(1), USE.NAMES = FALSE)
}
remote_size <- function(url) fetch_sizes(url)

# Run in a background R process: sequential download with .part files
download_tiles <- function(urls, dests) {
    options(timeout = 1e6)
    for (i in seq_along(urls)) {
        tmp <- paste0(dests[i], ".part")
        utils::download.file(urls[i], tmp, mode = "wb", quiet = TRUE)
        file.rename(tmp, dests[i])
    }
    TRUE
}

# ---- 3. CANOPY RASTER ---------------------------------------------------

local_laea <- function(poly_sf) {
    ctr <- with_planar(suppressWarnings(sf::st_coordinates(sf::st_centroid(sf::st_union(poly_sf)))))
    sprintf(
        "+proj=laea +lat_0=%.4f +lon_0=%.4f +datum=WGS84 +units=m +no_defs",
        ctr[2], wrap_lon(ctr[1])
    )
}

# max_dim: target size (cells) of the longest side of the final raster
get_canopy <- function(poly_sf, max_dim = 600, project = TRUE,
                       cache_dir = tempdir(), progress = function(...) NULL,
                       tile_dir = NULL) {
    bb <- sf::st_bbox(poly_sf)
    ext <- terra::ext(bb[["xmin"]], bb[["xmax"]], bb[["ymin"]], bb[["ymax"]])
    v <- terra::vect(poly_sf)

    native_cells <- max(
        (bb[["xmax"]] - bb[["xmin"]]) * 12000 * cos(mean(c(bb[["ymin"]], bb[["ymax"]])) * pi / 180),
        (bb[["ymax"]] - bb[["ymin"]]) * 12000
    )
    fact <- max(1L, ceiling(native_cells / max_dim))

    tt <- tile_table(poly_sf)
    # local file when present, otherwise stream from the server
    srcs <- vapply(seq_len(nrow(tt)), function(i) {
        f <- if (!is.null(tile_dir)) file.path(tile_dir, tt$name[i]) else ""
        if (file.exists(f)) f else tt$url[i]
    }, character(1))
    pieces <- list(); skipped <- character()
    for (i in seq_along(srcs)) {
        progress(i / length(srcs), sprintf("Tile %d of %d", i, length(srcs)))
        r <- tryCatch(
            terra::rast(srcs[i]),
            error = function(e) NULL # tile absent (ocean / no data)
        )
        if (is.null(r)) { skipped <- c(skipped, tt$name[i]); next }
        if (tt$shift[i] != 0) r <- terra::shift(r, dx = tt$shift[i]) # into the 0..360 frame
        r <- tryCatch(terra::crop(r, ext, snap = "out"), error = function(e) NULL)
        if (is.null(r)) { skipped <- c(skipped, tt$name[i]); next }
        # 255 = water / no-data flag in the ETH product
        r <- terra::clamp(r, lower = 0, upper = 100, values = FALSE)
        r <- if (fact > 1) terra::aggregate(r, fact = fact, fun = "mean", na.rm = TRUE) else r
        pieces[[length(pieces) + 1]] <- r
    }
    if (length(pieces) == 0) stop("No canopy-height tiles cover this region.")
    if (length(skipped)) warning("Could not read tile(s): ", paste(sub(".*2020_|_Map.tif", "", skipped), collapse = ", "),
        " - part of the region may be empty.", call. = FALSE)

    mosaic <- if (length(pieces) == 1) pieces[[1]] else
        do.call(terra::mosaic, pieces)
    mosaic <- terra::mask(mosaic, v)
    if (project) {
        mosaic <- terra::project(mosaic, local_laea(poly_sf), method = "bilinear")
    }
    mosaic <- terra::trim(mosaic)
    names(mosaic) <- "height"
    mosaic
}

# ---- 3b. MAP CONTEXT (graticule, scale, CRS, locator) --------------------

# Simplified world land outlines for the globe locator, as lon/lat rings (cached).
world_rings <- function(cache_dir = tempdir()) {
    f <- file.path(cache_dir, "world_rings.rds")
    if (file.exists(f)) return(readRDS(f))
    out <- tryCatch({
        w <- geodata::world(resolution = 5, level = 0, path = cache_dir)
        w <- terra::simplifyGeom(w, tolerance = 0.4, preserveTopology = FALSE)
        g <- terra::geom(w)
        g <- g[g[, "hole"] == 0, , drop = FALSE]
        key <- paste(g[, "geom"], g[, "part"])
        lapply(split(seq_len(nrow(g)), key), function(i) round(as.vector(t(g[i, c("x", "y")])), 1))
    }, error = function(e) NULL)
    if (!is.null(out)) { out <- unname(out); saveRDS(out, f) }
    out
}

# Everything the viewer needs to draw a map that is valid for publication:
# a faint lat/long grid (in the viewer's cell coordinates), scale, CRS and the
# region's lon/lat extent. `canopy` is the final (possibly projected) raster.
make_geo <- function(canopy, poly_sf, cache_dir = tempdir()) {
    crs <- terra::crs(canopy)
    lonlat <- terra::is.lonlat(canopy)
    e <- as.vector(terra::ext(canopy)); rs <- terra::res(canopy)
    nr <- terra::nrow(canopy); nc <- terra::ncol(canopy)
    to_xz <- function(X, Y) cbind((X - e[1]) / rs[1] - nc / 2, (e[4] - Y) / rs[2] - nr / 2)
    to_lonlat <- function(xy) if (lonlat) xy else terra::project(xy, from = crs, to = "EPSG:4326")
    from_lonlat <- function(xy) if (lonlat) xy else terra::project(xy, from = "EPSG:4326", to = crs)

    # padded frame (cells) that the ground plane / grid should cover
    pad <- 0.8 * max(nr, nc)
    box <- c(e[1] - pad * rs[1], e[2] + pad * rs[1], e[3] - pad * rs[2], e[4] + pad * rs[2])
    s <- seq(0, 1, length.out = 60)
    edge <- rbind(cbind(box[1] + s * (box[2] - box[1]), box[3]), cbind(box[2], box[3] + s * (box[4] - box[3])),
                  cbind(box[2] - s * (box[2] - box[1]), box[4]), cbind(box[1], box[4] - s * (box[4] - box[3])))
    ll <- to_lonlat(edge); ll <- ll[is.finite(ll[, 1]) & is.finite(ll[, 2]), , drop = FALSE]
    if (diff(range(ll[, 1])) > 180) ll[ll[, 1] < 0, 1] <- ll[ll[, 1] < 0, 1] + 360
    lonr <- range(ll[, 1]); latr <- pmax(pmin(range(ll[, 2]), 85), -85)

    span <- max(diff(lonr) * cos(mean(latr) * pi / 180), diff(latr))
    steps <- c(0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 15, 20, 30)
    step <- steps[which(span / steps <= 14)[1]]; if (is.na(step)) step <- 30
    lons <- seq(ceiling(lonr[1] / step) * step, floor(lonr[2] / step) * step, by = step)
    lats <- seq(ceiling(latr[1] / step) * step, floor(latr[2] / step) * step, by = step)
    dec <- if (step >= 1) 0 else if (step >= 0.1) 1 else 2

    lines <- list(); labels <- list()
    dimc <- max(nr, nc); pad_l <- 0.12 * dimc # labels sit on a frame just outside the region
    add_line <- function(lon, lat, kind, value) {
        pts <- from_lonlat(cbind(lon, lat)); xz <- to_xz(pts[, 1], pts[, 2])
        inside <- is.finite(xz[, 1]) & is.finite(xz[, 2]) &
            abs(xz[, 1]) <= nc / 2 + pad & abs(xz[, 2]) <= nr / 2 + pad
        if (sum(inside) < 2) return()
        runs <- rle(inside); end <- cumsum(runs$lengths); start <- end - runs$lengths + 1
        for (k in which(runs$values)) {
            seg <- xz[start[k]:end[k], , drop = FALSE]
            if (nrow(seg) >= 2) lines[[length(lines) + 1]] <<- round(as.vector(t(seg)), 2)
        }
        cand <- xz[inside, , drop = FALSE]
        if (kind == "lon") { # meridians: label where they cross the frame's southern edge
            zl <- nr / 2 + pad_l; j <- which.min(abs(cand[, 2] - zl))
            ok <- abs(cand[j, 2] - zl) < 0.03 * dimc && abs(cand[j, 1]) <= nc / 2 + pad_l
        } else {             # parallels: label where they cross the frame's western edge
            xl <- -nc / 2 - pad_l; j <- which.min(abs(cand[, 1] - xl))
            ok <- abs(cand[j, 1] - xl) < 0.03 * dimc && abs(cand[j, 2]) <= nr / 2 + pad_l
        }
        if (!ok) return()
        v <- wrap_lon(value)
        txt <- if (kind == "lon") sprintf("%s\u00b0%s", formatC(abs(v), format = "f", digits = dec), if (v >= 0) "E" else "W")
               else sprintf("%s\u00b0%s", formatC(abs(value), format = "f", digits = dec), if (value >= 0) "N" else "S")
        labels[[length(labels) + 1]] <<- list(t = txt, x = round(cand[j, 1], 2), z = round(cand[j, 2], 2), k = kind)
    }
    npt <- 240
    for (lo in lons) add_line(rep(lo, npt), seq(latr[1], latr[2], length.out = npt), "lon", lo)
    for (la in lats) add_line(seq(lonr[1], lonr[2], length.out = npt), rep(la, npt), "lat", la)

    bb <- with_planar(sf::st_bbox(poly_sf))
    ctr <- c((bb[["xmin"]] + bb[["xmax"]]) / 2, (bb[["ymin"]] + bb[["ymax"]]) / 2)
    cell_m <- if (lonlat) rs[1] * 111320 * cos(ctr[2] * pi / 180) else rs[1]
    hemi <- function(v, p, n) sprintf("%.2f\u00b0%s", abs(v), if (v >= 0) p else n)
    crs_label <- if (lonlat) "WGS 84 geographic (EPSG:4326)" else
        sprintf("Lambert azimuthal equal-area, centre %s %s (WGS 84)", hemi(ctr[2], "N", "S"), hemi(wrap_lon(ctr[1]), "E", "W"))
    list(
        grid = list(lines = lines, labels = labels, step = step),
        extent = unname(c(bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]])),
        center = unname(ctr), cell_m = cell_m, crs_label = crs_label,
        proj = terra::crs(canopy, proj = TRUE), approx_scale = lonlat,
        world = world_rings(cache_dir)
    )
}

# ---- 4. COLOURS ---------------------------------------------------------
# plot_gg() is fragile across ggplot2 versions, so the 3D scene is built
# straight from the height matrix; the legend is drawn with grid afterwards.

class_breaks <- function(canopy, n_breaks, break_style) {
    v <- terra::values(canopy, na.rm = TRUE)[, 1]
    unique(round(suppressWarnings(
        classInt::classIntervals(v, n = n_breaks, style = break_style)$brks
    ), 0))
}

make_texture <- function(canopy, palette, background) {
    m <- rayshader::raster_to_matrix(canopy)             # heights (rayshader x-by-y orientation)
    img <- terra::as.matrix(canopy, wide = TRUE)         # image orientation, which textures / shadow maps need
    cols <- grDevices::colorRampPalette(PALETTES[[palette]], bias = 2)(256)
    rng <- range(m, na.rm = TRUE)
    idx <- 1 + round(255 * (img - rng[1]) / max(diff(rng), 1e-9))
    hex <- matrix(cols[idx], nrow(img), ncol(img))
    hex[is.na(img)] <- background
    rgb <- t(grDevices::col2rgb(as.vector(hex))) / 255
    tex <- array(rgb, dim = c(nrow(img), ncol(img), 3))
    list(texture = tex, heights = replace(m, is.na(m), 0), cols = cols, range = rng)
}

# Draw a stepped legend onto an existing PNG (bottom-right corner)
add_legend <- function(file, brks, cols, rng, background, title = "height (m)") {
    img <- png::readPNG(file)
    h <- dim(img)[1]; w <- dim(img)[2]
    txt <- if (grDevices::col2rgb(background)[1] < 100) "grey90" else "grey10"
    grDevices::png(file, width = w, height = h)
    grid::grid.raster(img)
    n <- length(brks)
    sw <- grid::unit(0.022, "npc")
    x0 <- grid::unit(0.86, "npc"); y0 <- grid::unit(0.08, "npc")
    grid::grid.text(title, x = x0, y = y0 + sw * (n + 0.6), just = "left",
        gp = grid::gpar(col = txt, fontsize = h / 55))
    for (i in seq_len(n)) {
        mid <- brks[i]
        col <- cols[pmin(256, pmax(1, 1 + round(255 * (mid - rng[1]) / max(diff(rng), 1e-9))))]
        grid::grid.rect(x = x0, y = y0 + sw * (i - 1), width = sw, height = sw,
            just = c("left", "bottom"), gp = grid::gpar(fill = col, col = NA))
        grid::grid.text(brks[i], x = x0 + sw * 1.3, y = y0 + sw * (i - 0.5),
            just = "left", gp = grid::gpar(col = txt, fontsize = h / 65))
    }
    grDevices::dev.off()
    invisible(file)
}

# ---- 5. RAYSHADER RENDER ------------------------------------------------

# opts: list(palette, n_breaks, break_style, background, show_legend,
#            exaggeration, phi, theta, zoom, sunangle, shadow_intensity)
# mode: "preview" (fast snapshot) or "hq" (path-traced)
render_map <- function(canopy, opts, file, mode = c("preview", "hq"), hq_size = 3000) {
    mode <- match.arg(mode)
    tx <- make_texture(canopy, opts$palette, opts$background)
    hm <- tx$heights

    # vertical scale: tallest canopy rises ~5% of the map's long side x exaggeration
    zscale <- max(hm) / (0.05 * max(dim(hm)) * opts$exaggeration)
    zscale <- max(zscale, 1e-6)

    shade <- rayshader::ray_shade(hm, zscale = zscale, sunangle = opts$sunangle,
        sunaltitude = 45, multicore = TRUE)
    tex <- rayshader::add_shadow(tx$texture, shade, max_darken = 1 - 0.7 * opts$shadow_intensity)

    on.exit(try(rgl::close3d(), silent = TRUE), add = TRUE)
    rayshader::plot_3d(
        tex, hm, zscale = zscale, solid = FALSE,
        shadow = TRUE, shadowcolor = opts$background,
        background = opts$background, windowsize = c(900, 900),
        zoom = opts$zoom, phi = opts$phi, theta = opts$theta
    )

    if (mode == "preview") {
        rayshader::render_snapshot(filename = file, clear = FALSE)
    } else {
        rayshader::render_highquality(
            filename = file, preview = FALSE, parallel = TRUE, interactive = FALSE,
            light = TRUE,
            lightdirection = rep(opts$sunangle, 4) + c(0, 5, 0, 5),
            lightintensity = c(1200, 1750, 600, 700),
            lightaltitude = c(15, 15, 80, 80),
            ground_material = rayrender::microfacet(roughness = .6),
            width = hq_size, height = hq_size
        )
    }
    if (isTRUE(opts$show_legend)) {
        add_legend(file, class_breaks(canopy, opts$n_breaks, opts$break_style),
            tx$cols, tx$range, opts$background)
    }
    invisible(file)
}
