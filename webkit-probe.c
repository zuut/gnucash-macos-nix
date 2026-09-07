/* Minimal WebKitGTK rendering probe: loads HTML, reports load state,
 * evaluates JS, snapshots the view to PNG. */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

static WebKitWebView* view;
static int phase = 0;

static gboolean widget_capture(gpointer data)
{
    /* Draw the actual widget content - exercises AcceleratedBackingStore::paint. */
    GtkWidget* w = GTK_WIDGET(view);
    GtkAllocation alloc;
    gtk_widget_get_allocation(w, &alloc);
    cairo_surface_t* surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, alloc.width, alloc.height);
    cairo_t* cr = cairo_create(surf);
    gtk_widget_draw(w, cr);
    cairo_destroy(cr);
    cairo_surface_write_to_png(surf, "/tmp/webkit-widget.png");
    g_print("PROBE: widget draw written to /tmp/webkit-widget.png (%dx%d)\n", alloc.width, alloc.height);
    cairo_surface_destroy(surf);
    gtk_main_quit();
    return FALSE;
}

static void on_snapshot(GObject* src, GAsyncResult* res, gpointer data)
{
    GError* err = NULL;
    cairo_surface_t* surf = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(src), res, &err);
    if (err) {
        g_print("PROBE: snapshot FAILED: %s\n", err->message);
    } else {
        cairo_surface_write_to_png(surf, "/tmp/webkit-probe.png");
        g_print("PROBE: snapshot written to /tmp/webkit-probe.png (%dx%d)\n",
            cairo_image_surface_get_width(surf), cairo_image_surface_get_height(surf));
        cairo_surface_destroy(surf);
    }
    /* wait a bit for frames to flow, then capture the widget */
    g_timeout_add_seconds(3, widget_capture, NULL);
}

static void on_js(GObject* src, GAsyncResult* res, gpointer data)
{
    GError* err = NULL;
    JSCValue* v = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(src), res, &err);
    if (err)
        g_print("PROBE: JS FAILED: %s\n", err->message);
    else {
        char* s = jsc_value_to_string(v);
        g_print("PROBE: JS innerText = '%s'\n", s);
        g_free(s);
    }
    webkit_web_view_get_snapshot(view, WEBKIT_SNAPSHOT_REGION_VISIBLE,
        WEBKIT_SNAPSHOT_OPTIONS_NONE, NULL, on_snapshot, NULL);
}

static void on_load_changed(WebKitWebView* v, WebKitLoadEvent ev, gpointer data)
{
    g_print("PROBE: load event %d\n", ev);
    if (ev == WEBKIT_LOAD_FINISHED && phase == 0) {
        phase = 1;
        g_print("PROBE: LOAD FINISHED\n");
        webkit_web_view_evaluate_javascript(v, "document.body.innerText", -1,
            NULL, NULL, NULL, on_js, NULL);
    }
}

static void on_terminated(WebKitWebView* v, WebKitWebProcessTerminationReason r, gpointer data)
{
    g_print("PROBE: WEB PROCESS TERMINATED, reason %d\n", r);
    gtk_main_quit();
}

static gboolean on_timeout(gpointer data)
{
    g_print("PROBE: TIMEOUT (load never finished)\n");
    gtk_main_quit();
    return FALSE;
}

int main(int argc, char** argv)
{
    gtk_init(&argc, &argv);
    GtkWidget* win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(win), 480, 320);
    view = WEBKIT_WEB_VIEW(webkit_web_view_new());
    gtk_container_add(GTK_CONTAINER(win), GTK_WIDGET(view));
    g_signal_connect(view, "load-changed", G_CALLBACK(on_load_changed), NULL);
    g_signal_connect(view, "web-process-terminated", G_CALLBACK(on_terminated), NULL);
    gtk_widget_show_all(win);
    if (argc > 1) webkit_web_view_load_uri(view, argv[1]); else webkit_web_view_load_html(view,
        "<html><body style='background:#fff'><h1 style='color:red'>HELLO WEBKIT</h1></body></html>", NULL);
    g_timeout_add_seconds(20, on_timeout, NULL);
    gtk_main();
    return 0;
}
