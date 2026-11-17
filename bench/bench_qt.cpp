// bench_qt — minimal Qt6 "hello" for the Cipher framework comparison.
// Window 480x360, one button + one frame counter label, 120 frames then quit.
// Prints QT6_BENCH frames=120 total_ms=X rss_kb=X
#include <QApplication>
#include <QMainWindow>
#include <QVBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QTimer>
#include <QElapsedTimer>
#include <cstdio>
#include <cstring>

static int rss_kb_self() {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    while (fgets(line, sizeof line, f))
        if (strncmp(line, "VmHWM:", 6) == 0) { int kb = 0; sscanf(line + 6, "%d", &kb); fclose(f); return kb; }
    fclose(f); return -1;
}

int main(int argc, char **argv) {
    QElapsedTimer clock; clock.start();
    QApplication app(argc, argv);
    QMainWindow win;
    win.setWindowTitle("bench-qt");
    win.resize(480, 360);
    auto *central = new QWidget(&win);
    auto *layout = new QVBoxLayout(central);
    auto *label = new QLabel("frames: 0", central);
    auto *btn = new QPushButton("Click me", central);
    layout->addWidget(label);
    layout->addWidget(btn);
    win.setCentralWidget(central);
    win.show();
    static int frames = 0;
    QTimer timer;
    QObject::connect(&timer, &QTimer::timeout, [&]() {
        frames++;
        label->setText(QString("frames: %1").arg(frames));
        if (frames >= 120) {
            double ms = clock.elapsed();
            printf("QT6_BENCH frames=%d total_ms=%.1f rss_kb=%d\n", frames, ms, rss_kb_self());
            fflush(stdout);
            app.quit();
            timer.stop();
        }
    });
    timer.start(16);
    return app.exec();
}
