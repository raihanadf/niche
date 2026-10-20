#include "agents/procfs.h"

#include <QFile>
#include <QFileInfo>

#include <cstdlib>
#include <dirent.h>
#include <signal.h>

namespace
{
QByteArray readProc(qint64 pid, const char *entry)
{
    QFile file(QStringLiteral("/proc/%1/%2").arg(pid).arg(QLatin1StringView(entry)));
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return file.readAll();
}
}

QList<qint64> AgentProc::pids()
{
    QList<qint64> found;
    DIR *dir = opendir("/proc");
    if (!dir) {
        return found;
    }
    while (dirent *entry = readdir(dir)) {
        const char *name = entry->d_name;
        if (name[0] < '1' || name[0] > '9') {
            continue;
        }
        char *end = nullptr;
        const long long pid = std::strtoll(name, &end, 10);
        if (end && *end == '\0') {
            found.append(pid);
        }
    }
    closedir(dir);
    return found;
}

QList<QByteArray> AgentProc::cmdline(qint64 pid)
{
    const QByteArray raw = readProc(pid, "cmdline");
    QList<QByteArray> args = raw.split('\0');
    if (!args.isEmpty() && args.last().isEmpty()) {
        args.removeLast();
    }
    return args;
}

qint64 AgentProc::parentOf(qint64 pid)
{
    // "pid (comm) state ppid ..."; comm may contain spaces and parentheses.
    const QByteArray stat = readProc(pid, "stat");
    const qsizetype close = stat.lastIndexOf(')');
    if (close < 0) {
        return -1;
    }
    const QList<QByteArray> fields = stat.mid(close + 2).split(' ');
    if (fields.size() < 2) {
        return -1;
    }
    bool ok = false;
    const qint64 parent = fields.at(1).toLongLong(&ok);
    return ok ? parent : -1;
}

QHash<qint64, qint64> AgentProc::parents()
{
    QHash<qint64, qint64> map;
    const QList<qint64> all = pids();
    map.reserve(all.size());
    for (qint64 pid : all) {
        const qint64 parent = parentOf(pid);
        if (parent >= 0) {
            map.insert(pid, parent);
        }
    }
    return map;
}

QList<qint64> AgentProc::ancestors(qint64 pid, const QHash<qint64, qint64> &parents)
{
    QList<qint64> chain;
    qint64 current = pid;
    while (current > 1 && chain.size() < 128) {
        chain.append(current);
        current = parents.value(current, 0);
    }
    return chain;
}

QString AgentProc::exeName(qint64 pid)
{
    const QString target = QFile::symLinkTarget(QStringLiteral("/proc/%1/exe").arg(pid));
    return target.isEmpty() ? QString() : QFileInfo(target).fileName();
}

QString AgentProc::cwd(qint64 pid)
{
    const QString target = QFile::symLinkTarget(QStringLiteral("/proc/%1/cwd").arg(pid));
    if (target.isEmpty()) {
        return {};
    }
    const QString real = QFileInfo(target).canonicalFilePath();
    return real.isEmpty() ? target : real;
}

QByteArray AgentProc::environment(qint64 pid, const QByteArray &name)
{
    const QByteArray raw = readProc(pid, "environ");
    const QByteArray prefix = name + '=';
    qsizetype start = 0;
    while (start < raw.size()) {
        qsizetype end = raw.indexOf('\0', start);
        if (end < 0) {
            end = raw.size();
        }
        const QByteArrayView entry(raw.constData() + start, end - start);
        if (entry.startsWith(prefix)) {
            return entry.sliced(prefix.size()).toByteArray();
        }
        start = end + 1;
    }
    return {};
}

bool AgentProc::alive(qint64 pid)
{
    return pid > 1 && kill(static_cast<pid_t>(pid), 0) == 0;
}
