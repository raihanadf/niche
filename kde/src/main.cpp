#include "activities/liveactivities.h"
#include "agents/agentmonitor.h"
#include "clipboard/clipboardhistory.h"
#include "media/audiooutput.h"
#include "media/audiospectrum.h"
#include "media/mediaplayer.h"
#include "settings.h"
#include "shell.h"

#include <QApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickImageProvider>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QSocketNotifier>

#include <csignal>
#include <unistd.h>

namespace
{
const QString service = QStringLiteral("org.niche.Island");

// Runtime dependencies are baked in at build time instead of a wrapper script
// (see flake.nix); prepend them so the session's own entries still apply.
void prependPath(const char *variable, const char *dirs)
{
    if (!*dirs) {
        return;
    }
    QByteArray value = dirs;
    const QByteArray current = qgetenv(variable);
    if (!current.isEmpty()) {
        value += ':' + current;
    }
    qputenv(variable, value);
}

// SIGTERM/SIGINT quit through the event loop, so aboutToQuit cleanup (the
// KWin script, Wayland objects) runs like niche's signal sources.
int signalPipe[2];

void quitOnSignals(QObject *parent)
{
    if (pipe(signalPipe) != 0) {
        return;
    }
    auto notifier = new QSocketNotifier(signalPipe[0], QSocketNotifier::Read, parent);
    QObject::connect(notifier, &QSocketNotifier::activated, [] {
        char byte;
        if (read(signalPipe[0], &byte, 1) == 1) {
            QCoreApplication::quit();
        }
    });
    struct sigaction action = {};
    action.sa_handler = [](int) {
        const char byte = 1;
        (void)!write(signalPipe[1], &byte, 1);
    };
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, nullptr);
    sigaction(SIGINT, &action, nullptr);
}
}

int main(int argc, char *argv[])
{
    prependPath("QT_PLUGIN_PATH", NICHE_PLUGIN_PATH);
    prependPath("QML_IMPORT_PATH", NICHE_QML_PATH);
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        qputenv("QT_QPA_PLATFORM", "wayland");
    }

    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("niche-kde"));
    QApplication::setApplicationDisplayName(QStringLiteral("niche"));
    QApplication::setApplicationVersion(QStringLiteral(NICHE_VERSION));
    QApplication::setDesktopFileName(QStringLiteral("org.niche.Island"));
    QApplication::setQuitOnLastWindowClosed(false);
    QApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("niche-kde"), QIcon(QStringLiteral(":/qt/qml/Niche/assets/icon.png"))));

    // One island per session: a second launch opens the running one's settings.
    auto bus = QDBusConnection::sessionBus();
    if (!bus.registerService(service)) {
        bus.call(QDBusMessage::createMethodCall(service, QStringLiteral("/Shell"), QStringLiteral("org.niche.Shell"), QStringLiteral("openSettings")));
        return 0;
    }
    quitOnSignals(&app);

    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));
    }

    QQmlApplicationEngine engine;
    for (const QString &dir : QString::fromUtf8(NICHE_QML_PATH).split(QLatin1Char(':'), Qt::SkipEmptyParts)) {
        engine.addImportPath(dir);
    }

    auto settings = new Settings(&app);
    auto shell = new Shell(&engine, &app);
    auto media = new MediaPlayer(&app);
    auto output = new AudioOutput(&app);
    auto spectrum = new AudioSpectrum(&app);
    auto agents = new AgentMonitor(&app);
    auto clipboard = new ClipboardHistory(&app);
    auto activities = new LiveActivities(&app);

    QObject::connect(output, &AudioOutput::adjusted, activities, [output, activities] {
        activities->showVolume(output->volume(), output->muted());
    });

    qmlRegisterSingletonInstance("Niche", 1, 0, "Settings", settings);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Shell", shell);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Media", media);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Output", output);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Spectrum", spectrum);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Agents", agents);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Clipboard", clipboard);
    qmlRegisterSingletonInstance("Niche", 1, 0, "Activities", activities);
    engine.addImageProvider(QStringLiteral("clipboard"), clipboard->createImageProvider());

    engine.loadFromModule("Niche", "Main");
    auto window = engine.rootObjects().isEmpty() ? nullptr : qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!window) {
        qCritical("niche: the island failed to load");
        return 1;
    }
    shell->attach(window);

    return app.exec();
}
