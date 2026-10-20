#include "kwinscript.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QTimer>
#include <QUuid>

#include <functional>

namespace
{
const QString service = QStringLiteral("org.kde.KWin");
const QString scriptingPath = QStringLiteral("/Scripting");
const QString scriptingInterface = QStringLiteral("org.kde.kwin.Scripting");

QString scriptFile(const QString &pluginName)
{
    QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) + QStringLiteral("/niche-kde");
    QDir().mkpath(dir);
    return dir + QLatin1Char('/') + pluginName + QStringLiteral(".js");
}

QDBusMessage scriptingCall(const QString &method)
{
    return QDBusMessage::createMethodCall(service, scriptingPath, scriptingInterface, method);
}

void start(const QString &pluginName, const QString &source, std::function<void()> started)
{
    const QString path = scriptFile(pluginName);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning("niche: cannot write KWin script %s", qPrintable(path));
        return;
    }
    file.write(source.toUtf8());
    file.close();

    auto bus = QDBusConnection::sessionBus();
    QDBusMessage unload = scriptingCall(QStringLiteral("unloadScript"));
    unload << pluginName;
    auto unloading = new QDBusPendingCallWatcher(bus.asyncCall(unload));
    QObject::connect(unloading, &QDBusPendingCallWatcher::finished, unloading, [=](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        QDBusMessage loadCall = scriptingCall(QStringLiteral("loadScript"));
        loadCall << path << pluginName;
        auto loading = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(loadCall));
        QObject::connect(loading, &QDBusPendingCallWatcher::finished, loading, [=](QDBusPendingCallWatcher *w) {
            w->deleteLater();
            QDBusPendingReply<int> reply = *w;
            if (reply.isError() || reply.value() < 0) {
                qWarning("niche: KWin refused script %s: %s", qPrintable(pluginName), qPrintable(reply.error().message()));
                return;
            }
            QDBusMessage run = QDBusMessage::createMethodCall(service,
                                                              QStringLiteral("/Scripting/Script%1").arg(reply.value()),
                                                              QStringLiteral("org.kde.kwin.Script"),
                                                              QStringLiteral("run"));
            QDBusConnection::sessionBus().asyncCall(run);
            if (started) {
                started();
            }
        });
    });
}
}

void KWinScript::load(const QString &pluginName, const QString &source)
{
    start(pluginName, source, {});
}

void KWinScript::unload(const QString &pluginName)
{
    QDBusMessage call = scriptingCall(QStringLiteral("unloadScript"));
    call << pluginName;
    QDBusConnection::sessionBus().call(call, QDBus::NoBlock);
    QFile::remove(scriptFile(pluginName));
}

void KWinScript::runOnce(const QString &source)
{
    const QString name = QStringLiteral("niche-once-") + QUuid::createUuid().toString(QUuid::Id128).left(12);
    start(name, source, [name] {
        QTimer::singleShot(2000, [name] { KWinScript::unload(name); });
    });
}
