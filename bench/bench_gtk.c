/* bench_gtk — minimal GTK4 "hello" for the Cipher framework comparison.
 * Window 480x360, one button + one frame counter label, 120 frames then quit.
 * Prints GTK_BENCH frames=120 total_ms=X rss_kb=X
 */
#include <gtk/gtk.h>
#include <stdio.h>
#include <time.h>

static guint frames = 0;
static struct timespec t0;
static GtkWidget *label;
static int rss_kb_self(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (g_str_has_prefix(line, "VmHWM:")) {
            int kb = 0; sscanf(line + 6, "%d", &kb); fclose(f); return kb;
        }
    }
    fclose(f); return -1;
}
static gboolean tick(void) {
    frames++;
    char buf[64]; g_snprintf(buf, sizeof buf, "frames: %u", frames);
    gtk_label_set_text(GTK_LABEL(label), buf);
    if (frames >= 120) {
        struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
        double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
        g_print("GTK_BENCH frames=%u total_ms=%.1f rss_kb=%d\n", frames, ms, rss_kb_self());
        gtk_window_close(GTK_WINDOW(gtk_widget_get_root(label)));
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}
static void activate(GtkApplication *app, gpointer user_data) {
    (void)user_data;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    GtkWidget *win = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(win), "bench-gtk");
    gtk_window_set_default_size(GTK_WINDOW(win), 480, 360);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_top(box, 16); gtk_widget_set_margin_bottom(box, 16);
    gtk_widget_set_margin_start(box, 16); gtk_widget_set_margin_end(box, 16);
    label = gtk_label_new("frames: 0");
    GtkWidget *btn = gtk_button_new_with_label("Click me");
    gtk_box_append(GTK_BOX(box), label);
    gtk_box_append(GTK_BOX(box), btn);
    gtk_window_set_child(GTK_WINDOW(win), box);
    gtk_window_present(GTK_WINDOW(win));
    g_timeout_add(16, (GSourceFunc)tick, NULL);
}
int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("org.cipher.benchgtk", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int rc = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return rc;
}
