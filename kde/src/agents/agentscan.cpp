#include "agents/agentscan.h"

#include "agents/procfs.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>

#include <algorithm>
#include <optional>

namespace
{
// Last `bytes` of `path` split into lines; a partial first line is dropped.
QList<QByteArray> tailLines(const QString &path, qint64 bytes)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    const qint64 size = file.size();
    const qint64 start = size > bytes ? size - bytes : 0;
    if (!file.seek(start)) {
        return {};
    }
    QList<QByteArray> lines = file.readAll().split('\n');
    if (start > 0 && !lines.isEmpty()) {
        lines.removeFirst();
    }
    return lines;
}

QJsonObject parseObject(const QByteArray &line)
{
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(line, &error);
    return error.error == QJsonParseError::NoError ? document.object() : QJsonObject();
}

QString lastComponent(const QString &path)
{
    QString trimmed = path;
    while (trimmed.size() > 1 && trimmed.endsWith(QLatin1Char('/'))) {
        trimmed.chop(1);
    }
    const QString name = QFileInfo(trimmed).fileName();
    return name.isEmpty() ? trimmed : name;
}

QString resolved(const QString &path)
{
    const QString real = QFileInfo(path).canonicalFilePath();
    return real.isEmpty() ? path : real;
}

// Session files hold a pid that may have been reused after a crash; make
// sure it still runs claude (on NixOS the wrapped binary is ".claude-wrapped"
// with argv[0] "claude"; a node install has ".../claude-code/cli.js" in argv).
bool runsClaude(qint64 pid)
{
    if (AgentProc::exeName(pid).contains(QLatin1String("claude"), Qt::CaseInsensitive)) {
        return true;
    }
    const QList<QByteArray> args = AgentProc::cmdline(pid);
    for (qsizetype i = 0; i < std::min<qsizetype>(args.size(), 3); ++i) {
        if (args.at(i).toLower().contains("claude")) {
            return true;
        }
    }
    return false;
}

QString aiTitle(const QString &transcript)
{
    const QList<QByteArray> lines = tailLines(transcript, 256 * 1024);
    for (auto it = lines.crbegin(); it != lines.crend(); ++it) {
        if (!it->contains("\"ai-title\"")) {
            continue;
        }
        const QString title = parseObject(*it).value(QLatin1String("aiTitle")).toString();
        if (!title.isEmpty()) {
            return title;
        }
    }
    return {};
}

QByteArray fileName(const QByteArray &path)
{
    return path.mid(path.lastIndexOf('/') + 1);
}

struct OmpProcess {
    qint64 pid = 0;
    qint64 parent = 0;
    QString resume; // session id prefix given to --resume / --restore
};

// omp processes; on NixOS `bin/omp` execs `lib/omp/omp`, a bun build may run
// as `bun …/omp`, so look at the exe and the first two argv entries.
QList<OmpProcess> ompProcesses()
{
    QList<OmpProcess> rows;
    for (qint64 pid : AgentProc::pids()) {
        const QList<QByteArray> args = AgentProc::cmdline(pid);
        if (args.isEmpty()) {
            continue;
        }
        qsizetype index = -1;
        for (qsizetype i = 0; i < std::min<qsizetype>(args.size(), 2); ++i) {
            if (fileName(args.at(i)) == "omp") {
                index = i;
                break;
            }
        }
        if (index < 0 && AgentProc::exeName(pid) == QLatin1String("omp")) {
            index = 0;
        }
        if (index < 0) {
            continue;
        }
        OmpProcess row;
        row.pid = pid;
        bool worker = false;
        for (qsizetype i = index + 1; i < args.size(); ++i) {
            const QByteArray &arg = args.at(i);
            if (arg.startsWith("__omp_worker")) {
                worker = true;
                break;
            }
            QByteArray value;
            for (const char *flag : {"--resume", "--restore", "-r"}) {
                const QByteArray name(flag);
                if (arg == name) {
                    if (i + 1 < args.size() && !args.at(i + 1).startsWith('-')) {
                        value = args.at(i + 1);
                    }
                } else if (arg.startsWith(name) && arg.size() > name.size() && arg.at(name.size()) == '=') {
                    value = arg.mid(name.size() + 1);
                }
            }
            if (!value.isEmpty()) {
                // An id prefix or a session file path.
                QString id = QFileInfo(QString::fromLocal8Bit(value)).fileName();
                if (id.endsWith(QLatin1String(".jsonl"))) {
                    id.chop(6);
                }
                row.resume = id;
            }
        }
        // Daemon workers reparented to systemd must not count as launchers.
        if (worker) {
            continue;
        }
        row.parent = AgentProc::parentOf(pid);
        rows.append(row);
    }
    return rows;
}

// niche's state rule over the last 64 KB of an omp session file; nullopt when
// the session exited.
std::optional<bool> ompWorking(const QString &path)
{
    const QList<QByteArray> lines = tailLines(path, 64 * 1024);
    for (auto it = lines.crbegin(); it != lines.crend(); ++it) {
        const QByteArray &line = *it;
        if (line.contains("\"customType\":\"session_exit\"")) {
            return std::nullopt;
        }
        if (line.contains("\"customType\":\"tool_execution_start\"")) {
            return true;
        }
        if (!line.startsWith("{\"type\":\"message\"")) {
            continue;
        }
        const QJsonObject message = parseObject(line).value(QLatin1String("message")).toObject();
        const QString role = message.value(QLatin1String("role")).toString();
        if (role.isEmpty()) {
            continue;
        }
        return !(role == QLatin1String("assistant") && message.value(QLatin1String("stopReason")).toString() != QLatin1String("toolUse"));
    }
    return false;
}
}

QList<AgentSession> AgentScan::claudeSessions(TitleCache &cache)
{
    QList<AgentSession> found;
    QHash<QString, TitleCache::Entry> kept;
    const QString home = QDir::homePath();
    const QStringList configs =
        QDir(home).entryList({QStringLiteral(".claude*")}, QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &config : configs) {
        const QString base = home + QLatin1Char('/') + config;
        const QDir sessionsDir(base + QStringLiteral("/sessions"));
        const QStringList files = sessionsDir.entryList({QStringLiteral("*.json")}, QDir::Files | QDir::Hidden);
        if (files.isEmpty()) {
            continue;
        }
        const QString projectsRoot = base + QStringLiteral("/projects");
        const QStringList projectDirs = QDir(projectsRoot).entryList(QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot);
        QString account = config.mid(7); // after ".claude"
        while (account.startsWith(QLatin1Char('-'))) {
            account.remove(0, 1);
        }

        for (const QString &name : files) {
            QFile file(sessionsDir.filePath(name));
            if (!file.open(QIODevice::ReadOnly)) {
                continue;
            }
            const QJsonObject info = parseObject(file.readAll());
            file.close();
            const qint64 pid = info.value(QLatin1String("pid")).toInteger();
            const QString sessionId = info.value(QLatin1String("sessionId")).toString();
            const QString cwd = info.value(QLatin1String("cwd")).toString();
            if (pid <= 1 || sessionId.isEmpty() || cwd.isEmpty() || !AgentProc::alive(pid) || !runsClaude(pid)) {
                continue;
            }
            // Pre-spawned spares and the background daemon are not conversations.
            if (info.value(QLatin1String("spare")).toBool() || info.value(QLatin1String("kind")).toString() == QLatin1String("daemon")) {
                continue;
            }
            // Claude writes busy | shell | idle | waiting; a file written before the
            // first status update counts as paused.
            const QString status = info.value(QLatin1String("status")).toString();

            QString title = info.value(QLatin1String("name")).toString();
            const QString transcriptName = sessionId + QStringLiteral(".jsonl");
            for (const QString &dir : projectDirs) {
                const QString transcript = projectsRoot + QLatin1Char('/') + dir + QLatin1Char('/') + transcriptName;
                const QFileInfo transcriptInfo(transcript);
                if (!transcriptInfo.exists()) {
                    continue;
                }
                TitleCache::Entry entry = cache.entries.value(transcript);
                const QDateTime modified = transcriptInfo.lastModified();
                if (entry.size != transcriptInfo.size() || entry.modified != modified) {
                    const QString fresh = aiTitle(transcript);
                    // The ai-title line can scroll out of the tail window; keep the last one seen.
                    if (!fresh.isEmpty()) {
                        entry.title = fresh;
                    }
                    entry.size = transcriptInfo.size();
                    entry.modified = modified;
                }
                kept.insert(transcript, entry);
                if (!entry.title.isEmpty()) {
                    title = entry.title;
                }
                break;
            }

            AgentSession session;
            session.id = QStringLiteral("claude-") + sessionId;
            session.kind = QStringLiteral("claude");
            session.title = title.trimmed();
            session.account = account;
            session.project = lastComponent(cwd);
            session.working = status == QLatin1String("busy") || status == QLatin1String("shell");
            session.pid = pid;
            found.append(session);
        }
    }
    cache.entries = std::move(kept);
    std::sort(found.begin(), found.end(), [](const AgentSession &a, const AgentSession &b) { return a.id < b.id; });
    return found;
}

QList<AgentSession> AgentScan::ompSessions()
{
    const QList<OmpProcess> rows = ompProcesses();
    QSet<qint64> pids;
    for (const OmpProcess &row : rows) {
        pids.insert(row.pid);
    }
    QList<OmpProcess> launchers;
    for (const OmpProcess &row : rows) {
        if (!pids.contains(row.parent)) {
            launchers.append(row);
        }
    }
    if (launchers.isEmpty()) {
        return {};
    }
    std::sort(launchers.begin(), launchers.end(), [](const OmpProcess &a, const OmpProcess &b) { return a.pid < b.pid; });

    QHash<QString, qint64> resumed;
    QHash<QString, QList<qint64>> wanted; // resolved cwd -> fresh launcher pids
    for (const OmpProcess &launcher : launchers) {
        if (!launcher.resume.isEmpty()) {
            resumed.insert(launcher.resume, launcher.pid);
            continue;
        }
        const QString cwd = AgentProc::cwd(launcher.pid);
        if (!cwd.isEmpty()) {
            wanted[cwd].append(launcher.pid);
        }
    }

    QList<AgentSession> found;
    const QDir root(QDir::homePath() + QStringLiteral("/.omp/agent/sessions"));
    const QStringList dirs = root.entryList(QDir::Dirs | QDir::Hidden | QDir::NoDotAndDotDot, QDir::Name);
    for (const QString &dirName : dirs) {
        const QFileInfoList newest =
            QDir(root.filePath(dirName)).entryInfoList({QStringLiteral("*.jsonl")}, QDir::Files | QDir::Hidden, QDir::Time);
        for (qsizetype n = 0; n < std::min<qsizetype>(newest.size(), 4); ++n) {
            const QFileInfo &file = newest.at(n);
            QFile handle(file.filePath());
            if (!handle.open(QIODevice::ReadOnly)) {
                continue;
            }
            const QList<QByteArray> head = handle.read(4096).split('\n');
            handle.close();

            QString title;
            QString cwd;
            for (qsizetype i = 0; i < std::min<qsizetype>(head.size(), 3); ++i) {
                const QJsonObject entry = parseObject(head.at(i));
                const QString type = entry.value(QLatin1String("type")).toString();
                if (type == QLatin1String("title")) {
                    title = entry.value(QLatin1String("title")).toString();
                } else if (type == QLatin1String("session")) {
                    cwd = entry.value(QLatin1String("cwd")).toString();
                }
            }
            if (cwd.isEmpty()) {
                continue;
            }
            const QString real = resolved(cwd);
            const QString fileName = file.fileName();
            qint64 resumedPid = 0;
            for (auto it = resumed.cbegin(); it != resumed.cend(); ++it) {
                if (fileName.contains(it.key())) {
                    resumedPid = it.value();
                    break;
                }
            }
            if (resumedPid == 0 && wanted.value(real).isEmpty()) {
                continue;
            }

            const std::optional<bool> working = ompWorking(file.filePath());
            if (!working) {
                continue;
            }
            qint64 pid = resumedPid;
            if (pid == 0) {
                QList<qint64> &candidates = wanted[real];
                pid = candidates.takeFirst();
            }

            AgentSession session;
            session.id = QStringLiteral("omp-") + fileName;
            session.kind = QStringLiteral("omp");
            session.title = title.trimmed();
            session.project = lastComponent(cwd);
            session.working = *working;
            session.pid = pid;
            found.append(session);
        }
    }
    std::sort(found.begin(), found.end(), [](const AgentSession &a, const AgentSession &b) { return a.id < b.id; });
    return found;
}
