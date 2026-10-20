#include "agents/agentfocus.h"

#include "agents/procfs.h"

#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QStringList>

#include <pwd.h>
#include <unistd.h>

namespace
{
constexpr int toolTimeout = 1500;
constexpr int dbusTimeout = 1000;

// PATH first; a session started by the desktop may lack the per-user Nix
// profile, so look there too.
QString findTool(const QString &name)
{
    QString found = QStandardPaths::findExecutable(name);
    if (!found.isEmpty()) {
        return found;
    }
    QStringList dirs;
    if (const passwd *user = getpwuid(getuid())) {
        dirs << QStringLiteral("/etc/profiles/per-user/%1/bin").arg(QString::fromLocal8Bit(user->pw_name));
    }
    dirs << QDir::homePath() + QStringLiteral("/.nix-profile/bin") << QStringLiteral("/run/current-system/sw/bin")
         << QStringLiteral("/usr/local/bin") << QStringLiteral("/usr/bin");
    return QStandardPaths::findExecutable(name, dirs);
}

QByteArray run(const QString &program, const QStringList &arguments)
{
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.setStandardErrorFile(QProcess::nullDevice());
    process.start(QIODevice::ReadOnly);
    if (!process.waitForStarted(toolTimeout)) {
        qWarning("niche: could not run %s", qPrintable(program));
        return {};
    }
    if (!process.waitForFinished(toolTimeout)) {
        process.kill();
        process.waitForFinished(200);
        return {};
    }
    return process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0 ? process.readAllStandardOutput() : QByteArray();
}

struct TmuxPane {
    QString session;
    QString window;
    QString pane;
};

struct TmuxClient {
    qint64 activity = -1;
    QString name;
    qint64 pid = 0;
};

// niche: find the tmux pane whose shell is an ancestor of `pid` and switch the
// most recently active client to it. Returns the client pid, or 0.
qint64 switchTmux(const QList<qint64> &chain)
{
    const QString tmux = findTool(QStringLiteral("tmux"));
    if (tmux.isEmpty()) {
        return 0;
    }
    QHash<qint64, TmuxPane> panes;
    const QByteArray paneList =
        run(tmux, {QStringLiteral("list-panes"), QStringLiteral("-a"), QStringLiteral("-F"),
                   QStringLiteral("#{pane_pid}\t#{session_id}\t#{window_id}\t#{pane_id}")});
    for (const QByteArray &line : paneList.split('\n')) {
        const QList<QByteArray> parts = line.split('\t');
        bool ok = false;
        const qint64 shell = parts.value(0).toLongLong(&ok);
        if (parts.size() == 4 && ok) {
            panes.insert(shell, {QString::fromUtf8(parts.at(1)), QString::fromUtf8(parts.at(2)), QString::fromUtf8(parts.at(3))});
        }
    }
    const TmuxPane *target = nullptr;
    for (qint64 pid : chain) {
        auto it = panes.constFind(pid);
        if (it != panes.constEnd()) {
            target = &it.value();
            break;
        }
    }
    if (!target) {
        return 0;
    }

    TmuxClient client;
    const QByteArray clientList = run(tmux, {QStringLiteral("list-clients"), QStringLiteral("-F"),
                                             QStringLiteral("#{client_activity}\t#{client_name}\t#{client_pid}")});
    for (const QByteArray &line : clientList.split('\n')) {
        const QList<QByteArray> parts = line.split('\t');
        bool activityOk = false;
        bool pidOk = false;
        const qint64 activity = parts.value(0).toLongLong(&activityOk);
        const qint64 pid = parts.value(2).toLongLong(&pidOk);
        if (parts.size() == 3 && activityOk && pidOk && activity > client.activity) {
            client = {activity, QString::fromUtf8(parts.at(1)), pid};
        }
    }
    if (client.pid == 0) {
        return 0;
    }
    run(tmux, {QStringLiteral("switch-client"), QStringLiteral("-c"), client.name, QStringLiteral("-t"), target->session});
    run(tmux, {QStringLiteral("select-window"), QStringLiteral("-t"), target->window});
    run(tmux, {QStringLiteral("select-pane"), QStringLiteral("-t"), target->pane});
    return client.pid;
}

QDBusMessage konsoleCall(const QString &service, const QString &path, const QString &interface, const QString &method)
{
    return QDBusMessage::createMethodCall(service, path, interface, method);
}

// Konsole: the window/tab whose shell is in the chain becomes current.
// Returns the tab's displayed title so KWin can pick that konsole window.
QString selectKonsoleTab(const QList<qint64> &chain)
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    QDBusConnectionInterface *daemon = bus.interface();
    if (!daemon) {
        return {};
    }
    const QSet<qint64> pids(chain.cbegin(), chain.cend());
    const QDBusReply<QStringList> names = daemon->registeredServiceNames();
    if (!names.isValid()) {
        return {};
    }
    QString service;
    for (const QString &name : names.value()) {
        if (!name.startsWith(QLatin1String("org.kde.konsole"))) {
            continue;
        }
        const QDBusReply<uint> owner = daemon->servicePid(name);
        if (owner.isValid() && pids.contains(qint64(owner.value()))) {
            service = name;
            break;
        }
    }
    if (service.isEmpty()) {
        return {};
    }

    const QDBusMessage introspect = bus.call(konsoleCall(service, QStringLiteral("/Windows"),
                                                         QStringLiteral("org.freedesktop.DBus.Introspectable"),
                                                         QStringLiteral("Introspect")),
                                             QDBus::Block, dbusTimeout);
    if (introspect.type() != QDBusMessage::ReplyMessage || introspect.arguments().isEmpty()) {
        return {};
    }
    static const QRegularExpression node(QStringLiteral("<node name=\"(\\d+)\""));
    auto windows = node.globalMatch(introspect.arguments().constFirst().toString());
    while (windows.hasNext()) {
        const QString windowPath = QStringLiteral("/Windows/") + windows.next().captured(1);
        const QDBusMessage list = bus.call(konsoleCall(service, windowPath, QStringLiteral("org.kde.konsole.Window"),
                                                       QStringLiteral("sessionList")),
                                           QDBus::Block, dbusTimeout);
        if (list.type() != QDBusMessage::ReplyMessage || list.arguments().isEmpty()) {
            continue;
        }
        for (const QString &sessionId : list.arguments().constFirst().toStringList()) {
            const QString sessionPath = QStringLiteral("/Sessions/") + sessionId;
            const QDBusMessage shell = bus.call(konsoleCall(service, sessionPath, QStringLiteral("org.kde.konsole.Session"),
                                                            QStringLiteral("processId")),
                                                QDBus::Block, dbusTimeout);
            if (shell.type() != QDBusMessage::ReplyMessage || shell.arguments().isEmpty()
                || !pids.contains(shell.arguments().constFirst().toLongLong())) {
                continue;
            }
            QDBusMessage select = konsoleCall(service, windowPath, QStringLiteral("org.kde.konsole.Window"),
                                              QStringLiteral("setCurrentSession"));
            select << sessionId.toInt();
            bus.call(select, QDBus::Block, dbusTimeout);
            QDBusMessage titleCall = konsoleCall(service, sessionPath, QStringLiteral("org.kde.konsole.Session"),
                                                 QStringLiteral("title"));
            titleCall << 1; // DisplayedTitleRole
            const QDBusMessage title = bus.call(titleCall, QDBus::Block, dbusTimeout);
            return title.type() == QDBusMessage::ReplyMessage && !title.arguments().isEmpty()
                ? title.arguments().constFirst().toString()
                : QString();
        }
    }
    return {};
}

// kitty: focus the kitty window running the chain through remote control
// (needs allow_remote_control + listen_on, which export KITTY_LISTEN_ON).
// Returns that window's title, which becomes its OS window's caption.
QString selectKittyWindow(const QList<qint64> &chain)
{
    QByteArray windowId;
    QByteArray listenOn;
    for (qint64 pid : chain) {
        windowId = AgentProc::environment(pid, "KITTY_WINDOW_ID");
        if (!windowId.isEmpty()) {
            listenOn = AgentProc::environment(pid, "KITTY_LISTEN_ON");
            break;
        }
    }
    if (windowId.isEmpty() || listenOn.isEmpty()) {
        return {};
    }
    const QString kitty = findTool(QStringLiteral("kitty"));
    if (kitty.isEmpty()) {
        return {};
    }
    const QString to = QString::fromLocal8Bit(listenOn);
    const QString match = QStringLiteral("id:") + QString::fromLatin1(windowId);
    run(kitty, {QStringLiteral("@"), QStringLiteral("--to"), to, QStringLiteral("focus-window"), QStringLiteral("--match"), match});

    const qint64 id = windowId.toLongLong();
    const QJsonArray osWindows = QJsonDocument::fromJson(run(kitty, {QStringLiteral("@"), QStringLiteral("--to"), to, QStringLiteral("ls")})).array();
    for (const QJsonValue &osWindow : osWindows) {
        for (const QJsonValue &tab : osWindow.toObject().value(QLatin1String("tabs")).toArray()) {
            for (const QJsonValue &window : tab.toObject().value(QLatin1String("windows")).toArray()) {
                const QJsonObject object = window.toObject();
                if (object.value(QLatin1String("id")).toInteger() == id) {
                    return object.value(QLatin1String("title")).toString();
                }
            }
        }
    }
    return {};
}

// Activates the normal window owned by the nearest pid of the chain; among
// windows of the same process the one captioned `hint` wins, then the topmost.
// Without a match, the topmost known terminal is raised (niche's fallback).
QString activationScript(const QList<qint64> &chain, const QString &hint)
{
    QJsonArray pids;
    for (qint64 pid : chain) {
        pids.append(pid);
    }
    const QJsonArray terminals = {QStringLiteral("org.kde.konsole"), QStringLiteral("konsole"), QStringLiteral("kitty"),
                                  QStringLiteral("org.kde.yakuake"), QStringLiteral("alacritty"), QStringLiteral("foot"),
                                  QStringLiteral("org.wezfurlong.wezterm"), QStringLiteral("com.mitchellh.ghostty"),
                                  QStringLiteral("org.gnome.terminal"), QStringLiteral("org.gnome.ptyxis"),
                                  QStringLiteral("xterm")};
    const QJsonObject input{{QStringLiteral("chain"), pids}, {QStringLiteral("hint"), hint}, {QStringLiteral("terminals"), terminals}};
    const QString data = QString::fromUtf8(QJsonDocument(input).toJson(QJsonDocument::Compact));
    return QString::fromUtf8(R"JS((function () {
    const input = %1;
    const windows = workspace.stackingOrder || workspace.windowList();
    let best = null;
    let bestRank = -1;
    let bestHinted = false;
    for (let i = windows.length - 1; i >= 0; --i) {
        const w = windows[i];
        if (!w.normalWindow) continue;
        const rank = input.chain.indexOf(w.pid);
        if (rank < 0) continue;
        const hinted = input.hint.length > 0 && String(w.caption).indexOf(input.hint) === 0;
        if (best === null || rank < bestRank || (rank === bestRank && hinted && !bestHinted)) {
            best = w;
            bestRank = rank;
            bestHinted = hinted;
        }
    }
    for (let i = windows.length - 1; best === null && i >= 0; --i) {
        const w = windows[i];
        const cls = String(w.resourceClass).toLowerCase();
        const name = String(w.resourceName).toLowerCase();
        if (w.normalWindow && (input.terminals.indexOf(cls) >= 0 || input.terminals.indexOf(name) >= 0)) best = w;
    }
    if (best === null) {
        print("niche: found no terminal window for pid " + input.chain[0]);
        return;
    }
    if (best.minimized) best.minimized = false;
    workspace.activeWindow = best;
})();
)JS")
        .arg(data);
}
}

QString AgentFocus::prepare(qint64 pid)
{
    const QHash<qint64, qint64> parents = AgentProc::parents();
    qint64 appPid = pid;
    if (const qint64 client = switchTmux(AgentProc::ancestors(pid, parents))) {
        appPid = client;
    }
    const QList<qint64> chain = AgentProc::ancestors(appPid, parents);
    QString hint = selectKonsoleTab(chain);
    if (hint.isEmpty()) {
        hint = selectKittyWindow(chain);
    }
    return activationScript(chain, hint);
}
