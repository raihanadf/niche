#pragma once

#include <QDateTime>
#include <QHash>
#include <QList>
#include <QString>

// One live coding-agent session (niche's AgentSession).
struct AgentSession {
    QString id; // "claude-<sessionId>" or "omp-<file name>"
    QString kind; // "claude" | "omp"
    QString title; // empty when the agent has not named the session
    QString account; // ~/.claude-<account>; empty for the default config
    QString project; // last path component of the session's cwd
    bool working = false; // working vs paused
    qint64 pid = 0;

    bool operator==(const AgentSession &) const = default;
};

// Session discovery from the agents' own files plus /proc. Runs on a worker
// thread; never touches GUI objects.
namespace AgentScan
{
// Claude transcript path -> ai title, so unchanged transcripts are not re-read
// every refresh. Only live sessions stay in it.
struct TitleCache {
    struct Entry {
        qint64 size = -1;
        QDateTime modified;
        QString title;
    };
    QHash<QString, Entry> entries;
};

QList<AgentSession> claudeSessions(TitleCache &cache);
QList<AgentSession> ompSessions();
}
