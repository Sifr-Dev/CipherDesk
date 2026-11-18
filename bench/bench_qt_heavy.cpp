// bench_qt_heavy — Qt6 heavy-scene CPU comparison for bench-hello.zig.
// QMainWindow 900x560: 5 dim labels + 40 QPushButtons + 10 QCheckBoxes +
// 10 QSliders (~105 controls). Measures CPU time per FULL window paint
// (QWidget::render into a preallocated QImage) after one warm-up render.
// Prints BENCHQTS frames=N total_ms=T avg_frame_ms=A rss_kb=R
#include <QApplication>
#include <QMainWindow>
#include <QWidget>
#include <QGridLayout>
#include <QLabel>
#include <QPushButton>
#include <QCheckBox>
#include <QSlider>
#include <QImage>
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
    QApplication app(argc, argv);
    QMainWindow win;
    win.setWindowTitle("bench-qt-heavy");
    win.resize(900, 560);
    auto *central = new QWidget(&win);
    auto *grid = new QGridLayout(central);
    grid->setContentsMargins(6, 6, 6, 6);
    grid->setSpacing(2);
    int row = 0;
    for (int i = 0; i < 5; i++) {
        auto *l = new QLabel(QString("bench row %1 — the quick brown fox jumps over the lazy dog %1").arg(i), central);
        grid->addWidget(l, row++, 0, 1, 8);
    }
    for (int i = 0; i < 40; i++) {
        auto *b = new QPushButton(QString("Button %1").arg(i), central);
        grid->addWidget(b, 5 + i / 8, i % 8);
    }
    for (int i = 0; i < 10; i++) {
        auto *k = new QCheckBox(QString("check %1").arg(i), central);
        grid->addWidget(k, 10 + i / 5, i % 5);
    }
    for (int i = 0; i < 10; i++) {
        auto *s = new QSlider(Qt::Horizontal, central);
        s->setRange(0, 100);
        s->setValue(50);
        grid->addWidget(s, 12 + i / 5, i % 5);
    }
    win.setCentralWidget(central);
    win.show();

    QImage img(900, 560, QImage::Format_ARGB32_Premultiplied);
    img.fill(qRgb(4, 6, 11));
    win.render(&img); // warm-up (setup excluded)

    const int N = 120;
    QElapsedTimer clock;
    clock.start();
    for (int i = 0; i < N; i++) win.render(&img);
    const double total = clock.elapsed();
    std::printf("BENCHQTS frames=%d total_ms=%.1f avg_frame_ms=%.3f rss_kb=%d\n", N, total, total / N, rss_kb_self());
    std::fflush(stdout);
    return 0;
}
