/* bench_gtk_cairo — cairo/pango heavy-scene CPU benchmark for cipher-hello.
 * Nearest honest analog to Qt's QWidget::render() path available here:
 * cairo is GTK4's software renderer (CairoRenderer). This draws the SAME
 * scene as bench_hello.zig / bench_qt_heavy.cpp directly with cairo+pango
 * primitives (buttons, checkboxes, sliders, labels — same strings/count/
 * layout). It is NOT a GTK widget-tree repaint; GTK's own widget→surface
 * path segfaults on this box (documented in BENCH.md). For pure rendering
 * throughput comparison, though, it is exactly what GTK software mode would
 * rasterize per frame.
 * Prints BENCHGTK frames=N total_ms=T avg_frame_ms=A rss_kb=R
 */
#include <cairo.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <time.h>
#include <string.h>
#include <math.h>

#define W 900
#define H 560
#define _USE_MATH_DEFINES
#define BTN_N 40
#define CHK_N 10
#define SLD_N 10

static int rss_kb_self(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    while (fgets(line, sizeof line, f))
        if (strncmp(line, "VmHWM:", 6) == 0) { int kb = 0; sscanf(line + 6, "%d", &kb); fclose(f); return kb; }
    fclose(f); return -1;
}

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
    cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
}

static void draw_scene(cairo_t *cr, PangoLayout *layout) {
    /* background: void #04060b */
    cairo_set_source_rgb(cr, 0x04 / 255.0, 0x06 / 255.0, 0x0b / 255.0);
    cairo_paint(cr);

    cairo_set_font_size(cr, 13);

    /* panel surface #0a0d13 */
    rounded_rect(cr, 0, 0, W, H, 0);
    cairo_set_source_rgb(cr, 0x0a / 255.0, 0x0d / 255.0, 0x13 / 255.0);
    cairo_fill(cr);

    /* 5 dim labels */
    for (int i = 0; i < 5; i++) {
        char buf[128];
        snprintf(buf, sizeof buf, "bench row %d - the quick brown fox jumps over the lazy dog %d", i, i);
        pango_layout_set_text(layout, buf, -1);
        cairo_set_source_rgb(cr, 0x8a / 255.0, 0x93 / 255.0, 0xa6 / 255.0);
        cairo_move_to(cr, 8, 8 + i * 30.0);
        pango_cairo_show_layout(cr, layout);
    }
    /* 40 buttons (#141a26 fill, hairline, centered text) */
    const double bw = 200, bh = 26, gap = 8;
    cairo_set_font_size(cr, 12);
    for (int i = 0; i < BTN_N; i++) {
        int col = i % 4, row = i / 4;
        double bx = 8 + col * (bw + gap), by = 170 + row * (bh + gap);
        rounded_rect(cr, bx, by, bw, bh, 3);
        cairo_set_source_rgb(cr, 0x14 / 255.0, 0x1a / 255.0, 0x26 / 255.0);
        cairo_fill(cr);
        cairo_set_source_rgb(cr, 0x1c / 255.0, 0x24 / 255.0, 0x34 / 255.0);
        cairo_set_line_width(cr, 1);
        cairo_stroke(cr);
        char buf[32];
        snprintf(buf, sizeof buf, "Button %d", i);
        pango_layout_set_text(layout, buf, -1);
        int tw = 0, th = 0;
        pango_layout_get_pixel_size(layout, &tw, &th);
        cairo_set_source_rgb(cr, 0xe8 / 255.0, 0xec / 255.0, 0xf4 / 255.0);
        cairo_move_to(cr, bx + (bw - tw) / 2.0, by + (bh - th) / 2.0);
        pango_cairo_show_layout(cr, layout);
    }
    /* 10 checkboxes */
    for (int i = 0; i < CHK_N; i++) {
        double cy = 470 + (i % 5) * 18.0, cx = 8 + (i / 5) * 200.0;
        cairo_rectangle(cr, cx, cy, 12, 12);
        cairo_set_source_rgb(cr, 0x14 / 255.0, 0x1a / 255.0, 0x26 / 255.0);
        cairo_fill(cr);
        cairo_set_source_rgb(cr, 0x1c / 255.0, 0x24 / 255.0, 0x34 / 255.0);
        cairo_set_line_width(cr, 1);
        cairo_stroke(cr);
        char buf[32];
        snprintf(buf, sizeof buf, "check %d", i);
        pango_layout_set_text(layout, buf, -1);
        cairo_set_source_rgb(cr, 0xe8 / 255.0, 0xec / 255.0, 0xf4 / 255.0);
        cairo_move_to(cr, cx + 18, cy);
        pango_cairo_show_layout(cr, layout);
    }
    /* 10 sliders */
    for (int i = 0; i < SLD_N; i++) {
        double cy = 160 + i * 30.0, cx = 700;
        cairo_rectangle(cr, cx, cy, 180, 4);
        cairo_set_source_rgb(cr, 0x14 / 255.0, 0x1a / 255.0, 0x26 / 255.0);
        cairo_fill(cr);
        cairo_rectangle(cr, cx + 60, cy - 7, 10, 18);
        cairo_set_source_rgb(cr, 0xe8 / 255.0, 0xec / 255.0, 0xf4 / 255.0);
        cairo_fill(cr);
    }
}

int main(void) {
    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, W, H);
    cairo_t *cr = cairo_create(surf);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    draw_scene(cr, layout); /* warm-up */
    const int N = 120;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < N; i++) draw_scene(cr, layout);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    printf("BENCHGTK frames=%d total_ms=%.1f avg_frame_ms=%.3f rss_kb=%d\n", N, ms, ms / N, rss_kb_self());
    fflush(stdout);
    cairo_surface_write_to_png(surf, "/tmp/opencode/bench_gtk_cairo.png");
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);
    return 0;
}
