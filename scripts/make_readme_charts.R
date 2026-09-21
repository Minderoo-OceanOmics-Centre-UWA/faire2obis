### make_readme_charts.R
#
# Generates the two README charts (docs/img/) from real pipeline output.
# Not part of the conversion pipeline itself - run manually after the
# archive has been rebuilt, if the numbers in the README need refreshing.
# Palette: reference instance from the dataviz skill (palette.md) -
# categorical slots 1 (blue #2a78d6) + de-emphasis gray, used unmodified.

suppressMessages(library(ggplot2))
suppressMessages(library(readr))
suppressMessages(library(dplyr))

dir.create("docs/img", recursive = TRUE, showWarnings = FALSE)

BLUE       <- "#2a78d6"
GRAY       <- "#c3c2b7"
INK        <- "#0b0b0b"
INK_MUTED  <- "#898781"
GRID       <- "#e1e0d9"
SURFACE    <- "#fcfcfb"

base_theme <- theme_minimal(base_size = 15) +
  theme(
    text                = element_text(color = INK),
    plot.background     = element_rect(fill = SURFACE, color = NA),
    panel.background    = element_rect(fill = SURFACE, color = NA),
    panel.grid.minor    = element_blank(),
    panel.grid.major.x  = element_blank(),
    panel.grid.major.y  = element_line(color = GRID, linewidth = 0.4),
    axis.text           = element_text(color = INK_MUTED),
    axis.title          = element_blank(),
    axis.ticks          = element_blank(),
    plot.title          = element_text(face = "bold", color = INK, size = 17, margin = margin(b = 4)),
    plot.subtitle       = element_text(color = INK_MUTED, size = 12, margin = margin(b = 14)),
    legend.position     = "none",
    plot.margin         = margin(16, 24, 12, 12)
  )

# ------------------------------------------------------------------
# Chart A: samples collected - emphasis form (real = accent, both
# control types = de-emphasis gray, since the story is "what's
# actually published" vs "excluded QC artifacts")
# ------------------------------------------------------------------
samples <- tibble(
  category = factor(
    c("Real samples\n(in the archive)", "Negative controls\n(excluded)", "Positive controls\n(excluded)"),
    levels = c("Real samples\n(in the archive)", "Negative controls\n(excluded)", "Positive controls\n(excluded)")
  ),
  n = c(490, 131, 7),
  is_real = c(TRUE, FALSE, FALSE)
)

p1 <- ggplot(samples, aes(x = category, y = n, fill = is_real)) +
  geom_col(width = 0.55) +
  geom_text(aes(label = n), vjust = -0.6, color = INK, size = 5, fontface = "bold") +
  scale_fill_manual(values = c(`TRUE` = BLUE, `FALSE` = GRAY)) +
  scale_y_continuous(limits = c(0, 560), expand = expansion(mult = c(0, 0.05))) +
  labs(
    title    = "Samples collected, OcOm_2408",
    subtitle = "Control samples are excluded from the published Occurrence extension"
  ) +
  base_theme

ggsave("docs/img/samples_breakdown.png", p1, width = 7.5, height = 4.6, dpi = 200, bg = SURFACE)

# ------------------------------------------------------------------
# Chart B: detections per assay - sequential (one hue, magnitude
# comparison) - Occurrence rows == DNA Derived Data rows per assay by
# design (validated in 05_qc_checks.R), so one number per assay covers
# both extensions.
# ------------------------------------------------------------------
detections <- tibble(
  assay = factor(c("16SFishD", "MarVer1", "MiFishUE2"), levels = c("16SFishD", "MarVer1", "MiFishUE2")),
  n = c(17595, 32234, 18600)
)

p2 <- ggplot(detections, aes(x = assay, y = n)) +
  geom_col(fill = BLUE, width = 0.5) +
  geom_text(aes(label = format(n, big.mark = ",")), vjust = -0.6, color = INK, size = 5, fontface = "bold") +
  scale_y_continuous(limits = c(0, 35000), labels = scales::comma, expand = expansion(mult = c(0, 0.05))) +
  labs(
    title    = "Detections per assay",
    subtitle = "Rows in each Occurrence extension (= matching DNA Derived Data extension row count)"
  ) +
  base_theme

ggsave("docs/img/detections_per_assay.png", p2, width = 7.5, height = 4.6, dpi = 200, bg = SURFACE)

cat("Written docs/img/samples_breakdown.png and docs/img/detections_per_assay.png\n")
