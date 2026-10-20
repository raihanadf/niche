#include "shell.h"

#include "kwinscript.h"

#include <KStatusNotifierItem>
#include <LayerShellQt/Window>

#include <QCoreApplication>
#include <QDBusConnection>
#include <QGuiApplication>
#include <QMenu>
#include <QPainter>
#include <QPainterPath>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QRegion>
#include <QScreen>
#include <QTimer>

#include <malloc.h>

namespace
{
const QString fullscreenScript = QStringLiteral("niche-fullscreen");

// Reports Plasma's primary output, and for every output whether the topmost
// visible normal window on it is fullscreen. Only sends on change. The island's
// own surface (NICHE_PID) counts as a normal window to KWin, so it's skipped.
const char fullscreenSource[] = R"JS(
const self = NICHE_PID;
const island = "org.niche.Island";
let last = null;
let lastPrimary = null;
function onDesktop(w) {
    return w.onAllDesktops || w.desktops.indexOf(workspace.currentDesktop) >= 0;
}
function reportPrimary() {
    const order = workspace.screenOrder || workspace.screens;
    const primary = order.length > 0 ? order[0].name : "";
    if (primary === lastPrimary) return;
    lastPrimary = primary;
    callDBus(island, "/Shell", "org.niche.Shell", "setPrimaryOutput", primary);
}
// `gone` is a window being removed: KWin still lists it in stackingOrder while
// windowRemoved runs.
function report(gone) {
    const order = workspace.stackingOrder;
    const decided = {};
    const full = [];
    for (let i = order.length - 1; i >= 0; --i) {
        const w = order[i];
        if (!w || w === gone || w.deleted || w.pid === self || !w.output || w.minimized || !w.normalWindow || !onDesktop(w)) continue;
        const name = w.output.name;
        if (decided[name]) continue;
        decided[name] = true;
        if (w.fullScreen) full.push(name);
    }
    const answer = full.join(",");
    if (answer === last) return;
    last = answer;
    callDBus(island, "/Shell", "org.niche.Shell", "setFullscreenOutputs", answer);
}
function update() {
    report(null);
}
function track(w) {
    if (!w || w.pid === self) return;
    w.fullScreenChanged.connect(update);
    w.minimizedChanged.connect(update);
    w.outputChanged.connect(update);
    w.desktopsChanged.connect(update);
}
workspace.windowList().forEach(track);
workspace.windowAdded.connect(function (w) { track(w); update(); });
workspace.windowRemoved.connect(function (w) { report(w); });
function activated(w) {
    if (w && w.pid !== self)
        callDBus(island, "/Shell", "org.niche.Shell", "setLastActiveWindow", w.internalId.toString());
    update();
}
workspace.windowActivated.connect(activated);
workspace.currentDesktopChanged.connect(update);
if (workspace.stackingOrderChanged) workspace.stackingOrderChanged.connect(update);
if (workspace.screenOrderChanged) workspace.screenOrderChanged.connect(reportPrimary);
workspace.screensChanged.connect(reportPrimary);
reportPrimary();
activated(workspace.activeWindow);
)JS";

QIcon trayIcon()
{
    // niche's menu bar mark: a rounded screen with the island on top.
    QIcon icon;
    const QColor ink = QGuiApplication::palette().windowText().color();
    for (int size : {16, 22, 32, 48}) {
        QPixmap pixmap(size, size);
        pixmap.fill(Qt::transparent);
        QPainter p(&pixmap);
        p.setRenderHint(QPainter::Antialiasing);
        const qreal s = size / 20.0;
        p.setPen(QPen(ink, 1.6 * s));
        p.drawRoundedRect(QRectF(2 * s, 3.5 * s, 16 * s, 13 * s), 3.6 * s, 3.6 * s);
        p.setPen(Qt::NoPen);
        p.setBrush(ink);
        p.drawRoundedRect(QRectF(6.6 * s, 5.6 * s, 6.8 * s, 2.6 * s), 1.3 * s, 1.3 * s);
        icon.addPixmap(pixmap);
    }
    return icon;
}
}

Shell::Shell(QQmlEngine *engine, QObject *parent)
    : QObject(parent)
    , m_engine(engine)
{
    auto bus = QDBusConnection::sessionBus();
    bus.registerObject(QStringLiteral("/Shell"), this, QDBusConnection::ExportScriptableSlots);
    bus.connect(QStringLiteral("org.freedesktop.ScreenSaver"),
                QStringLiteral("/ScreenSaver"),
                QStringLiteral("org.freedesktop.ScreenSaver"),
                QStringLiteral("ActiveChanged"),
                this,
                SLOT(screenSaverChanged(bool)));
    loadFullscreenScript();
    connect(qApp, &QCoreApplication::aboutToQuit, this, [] {
        KWinScript::unload(fullscreenScript);
    });
    setShowInTray(true);
}

Shell::~Shell() = default;

void Shell::attach(QQuickWindow *window)
{
    m_window = window;
    window->setColor(Qt::transparent);
    window->setFlag(Qt::FramelessWindowHint);

    auto layer = LayerShellQt::Window::get(window);
    layer->setLayer(LayerShellQt::Window::LayerOverlay);
    layer->setAnchors(LayerShellQt::Window::AnchorTop);
    // -1: ignore panels' exclusive zones so the island sits at the very top.
    layer->setExclusiveZone(-1);
    layer->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityNone);
    layer->setScope(QStringLiteral("niche"));
    layer->setActivateOnShow(false);

    connect(window, &QWindow::activeChanged, this, [this] {
        if (m_keyboardGrab && m_window && !m_window->isActive()) {
            setKeyboardGrab(false);
        }
    });
    // Wait briefly for the KWin script to name Plasma's primary output (Qt's
    // primaryScreen is just the first output announced), then show.
    connect(qGuiApp, &QGuiApplication::screenAdded, this, &Shell::placeOnPrimary);
    connect(qGuiApp, &QGuiApplication::screenRemoved, this, &Shell::placeOnPrimary);
    QTimer::singleShot(1500, this, [this] {
        m_placed = true;
        placeOnPrimary();
    });
}

QScreen *Shell::primaryScreen() const
{
    for (QScreen *screen : QGuiApplication::screens()) {
        if (screen->name() == m_primaryOutput) {
            return screen;
        }
    }
    return QGuiApplication::primaryScreen();
}

void Shell::placeOnPrimary()
{
    QScreen *screen = primaryScreen();
    if (!m_window || !screen || !m_placed) {
        return;
    }
    if (m_window->isVisible() && m_window->screen() == screen) {
        return;
    }
    m_window->hide();
    LayerShellQt::Window::get(m_window)->setScreen(screen);
    m_window->setScreen(screen);
    updateVisibility();
}

void Shell::setPrimaryOutput(const QString &output)
{
    m_primaryOutput = output;
    m_placed = true;
    placeOnPrimary();
}

void Shell::updateVisibility()
{
    if (!m_window) {
        return;
    }
    const QString output = m_window->screen() ? m_window->screen()->name() : QString();
    const bool full = !output.isEmpty() && m_fullscreenOutputs.contains(output);
    if (full != m_fullscreen) {
        m_fullscreen = full;
        Q_EMIT fullscreenChanged();
    }
    if (m_fullscreen && m_keyboardGrab) {
        setKeyboardGrab(false);
    }
    if (m_placed) {
        m_window->setVisible(!m_fullscreen);
    }
}

void Shell::loadFullscreenScript()
{
    QString source = QString::fromUtf8(fullscreenSource);
    source.replace(QStringLiteral("NICHE_PID"), QString::number(QCoreApplication::applicationPid()));
    KWinScript::load(fullscreenScript, source);
}

void Shell::setFullscreenOutputs(const QString &outputs)
{
    m_fullscreenOutputs = outputs.split(QLatin1Char(','), Qt::SkipEmptyParts);
    updateVisibility();
}

void Shell::setLastActiveWindow(const QString &internalId)
{
    m_lastActiveWindow = internalId;
}

bool Shell::fullscreen() const
{
    return m_fullscreen;
}

bool Shell::locked() const
{
    return m_locked;
}

void Shell::screenSaverChanged(bool active)
{
    if (active == m_locked) {
        return;
    }
    m_locked = active;
    Q_EMIT lockedChanged();
}

bool Shell::keyboardGrab() const
{
    return m_keyboardGrab;
}

void Shell::setKeyboardGrab(bool grab)
{
    if (grab == m_keyboardGrab || !m_window) {
        return;
    }
    m_keyboardGrab = grab;
    // KWin makes the island its active window while it holds the keyboard and
    // keeps it that way after release, so hand activation back to the window
    // the user was in (where pick-to-paste sends Ctrl+V) unless they already
    // clicked somewhere else.
    const bool restore = !grab && m_window->isActive() && !m_lastActiveWindow.isEmpty();
    LayerShellQt::Window::get(m_window)->setKeyboardInteractivity(grab ? LayerShellQt::Window::KeyboardInteractivityExclusive
                                                                       : LayerShellQt::Window::KeyboardInteractivityNone);
    if (restore) {
        KWinScript::runOnce(QStringLiteral("for (const w of workspace.windowList()) {"
                                           "  if (w.internalId.toString() === '%1') { workspace.activeWindow = w; break; }"
                                           "}")
                                .arg(m_lastActiveWindow));
    }
    Q_EMIT keyboardGrabChanged();
}

void Shell::setInputRect(const QRectF &rect)
{
    if (!m_window) {
        return;
    }
    // An empty QRegion would mean "no mask" (whole window), so keep at least a
    // pixel.
    const QRect r = rect.toAlignedRect().intersected(QRect(QPoint(0, 0), m_window->size()));
    m_window->setMask(QRegion(r.isEmpty() ? QRect(0, 0, 1, 1) : r));
}

void Shell::relieveMemory()
{
    QTimer::singleShot(1500, this, [this] {
        if (m_window) {
            m_window->releaseResources();
        }
        malloc_trim(0);
    });
}

bool Shell::showInTray() const
{
    return m_showInTray;
}

void Shell::setShowInTray(bool show)
{
    if (show == (m_tray != nullptr)) {
        m_showInTray = show;
        return;
    }
    m_showInTray = show;
    if (show) {
        m_tray = new KStatusNotifierItem(QStringLiteral("niche-kde"), this);
        m_tray->setCategory(KStatusNotifierItem::ApplicationStatus);
        m_tray->setStatus(KStatusNotifierItem::Active);
        m_tray->setTitle(QStringLiteral("niche"));
        m_tray->setToolTip(trayIcon(), QStringLiteral("niche"), QStringLiteral("Right-click the island for settings"));
        m_tray->setIconByPixmap(trayIcon());
        m_tray->setStandardActionsEnabled(false);
        auto menu = new QMenu();
        menu->addAction(QIcon::fromTheme(QStringLiteral("configure")), QStringLiteral("Settings…"), this, &Shell::openSettings);
        menu->addSeparator();
        menu->addAction(QIcon::fromTheme(QStringLiteral("application-exit")), QStringLiteral("Quit"), this, &Shell::quit);
        m_tray->setContextMenu(menu);
        connect(m_tray, &KStatusNotifierItem::activateRequested, this, &Shell::openSettings);
    } else {
        delete m_tray;
        m_tray = nullptr;
    }
    Q_EMIT showInTrayChanged();
}

void Shell::openSettings()
{
    if (auto window = qobject_cast<QQuickWindow *>(m_settingsWindow.data())) {
        window->show();
        window->raise();
        window->requestActivate();
        return;
    }
    QQmlComponent component(m_engine, QStringLiteral("Niche"), QStringLiteral("SettingsWindow"));
    QObject *object = component.create();
    if (!object) {
        qWarning("niche: settings window failed: %s", qPrintable(component.errorString()));
        return;
    }
    m_settingsWindow = object;
    if (auto window = qobject_cast<QQuickWindow *>(object)) {
        connect(window, &QWindow::visibleChanged, object, [object](bool visible) {
            if (!visible) {
                object->deleteLater();
            }
        });
        window->show();
        window->requestActivate();
    }
}

void Shell::quit()
{
    QCoreApplication::quit();
}
