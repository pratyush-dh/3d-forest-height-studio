# Writes THIRD_PARTY_NOTICES.txt for the bundle from the installed packages' DESCRIPTION files.
# Usage: Rscript make_notices.R <bundle lib> <output file> <app version>
args <- commandArgs(trailingOnly = TRUE)
lib <- args[1]; out <- args[2]; ver <- args[3]
inst <- installed.packages(lib.loc = lib)
pk <- data.frame(Package = inst[, "Package"], Version = inst[, "Version"], License = inst[, "License"], stringsAsFactors = FALSE)
pk <- pk[order(pk$Package), ]

head <- c(
    sprintf("3D Forest Height Studio %s - third-party notices", ver),
    strrep("=", 60), "",
    "3D Forest Height Studio itself is released under the MIT License (see LICENSE).",
    "",
    "CONCEPT",
    "  The visualisation idea builds on Milos Popovic's 3D forest height tutorial:",
    "  https://github.com/milos-agathon/3d-forest-height-maps",
    "  https://www.youtube.com/watch?v=4ScYWPMzy6E",
    "  No code from that repository is included.",
    "",
    "BUNDLED RUNTIME",
    sprintf("  R %s - GNU GPL (v2 or v3). Source code: https://cran.r-project.org/sources.html", as.character(getRversion())),
    "  R's own license texts are in the R\\doc and R\\share\\licenses folders where present.",
    "  three.js r160 (3D engine) - MIT License; see studio\\app\\www\\vendor\\three\\LICENSE.",
    "",
    "DATA (downloaded by the app at run time, not redistributed in this installer)",
    "  ETH Zurich Global Canopy Height 2020 - Lang, N., Jetz, W., Schindler, K., Wegner, J.D. (2023),",
    "    Nature Ecology & Evolution 7, 1778-1789. Please follow the dataset's terms of use.",
    "  GADM 4.1 administrative boundaries - https://gadm.org/license.html (check the terms before commercial use).",
    "",
    "BUNDLED R PACKAGES (name, version, license as declared by each package)"
)
body <- sprintf("  %-18s %-10s %s", pk$Package, pk$Version, pk$License)
writeLines(c(head, body, ""), out, useBytes = TRUE)
cat("Wrote", out, "with", nrow(pk), "packages\n")
