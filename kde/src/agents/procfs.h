#pragma once

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QString>

// Small readers over /proc, the Linux stand-in for niche's ps and lsof calls.
// Every function is safe to call from worker threads.
namespace AgentProc
{
// Numeric entries of /proc.
QList<qint64> pids();

// argv of `pid`, without the empty element after the final NUL.
QList<QByteArray> cmdline(qint64 pid);

// Parent pid from /proc/<pid>/stat, or -1 when the process is gone.
qint64 parentOf(qint64 pid);

// pid -> parent pid for every process (niche's `ps -Ao pid=,ppid=`).
QHash<qint64, qint64> parents();

// `pid` followed by its ancestors, nearest first, stopping before init.
QList<qint64> ancestors(qint64 pid, const QHash<qint64, qint64> &parents);

// File name of /proc/<pid>/exe ("" when unreadable).
QString exeName(qint64 pid);

// Working directory of `pid` with symlinks resolved ("" when unreadable).
QString cwd(qint64 pid);

// Value of the environment variable `name` in /proc/<pid>/environ.
QByteArray environment(qint64 pid, const QByteArray &name);

// kill(pid, 0) succeeds.
bool alive(qint64 pid);
}
