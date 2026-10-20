#include "agents/agentmonitor.h"

#include "agents/agentfocus.h"
#include "kwinscript.h"

#include <QFuture>
#include <QSet>
#include <QtConcurrent/QtConcurrentRun>

namespace
{
const QString claudeKind = QStringLiteral("claude");
const QString ompKind = QStringLiteral("omp");
constexpr int refreshInterval = 2000; // niche: every 2 s
}

AgentSessionModel::AgentSessionModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int AgentSessionModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_sessions.size());
}

QVariant AgentSessionModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_sessions.size()) {
        return {};
    }
    const AgentSession &session = m_sessions.at(index.row());
    switch (role) {
    case SessionIdRole:
        return session.id;
    case KindRole:
        return session.kind;
    case Qt::DisplayRole:
    case TitleRole:
        return session.title;
    case AccountRole:
        return session.account;
    case ProjectRole:
        return session.project;
    case WorkingRole:
        return session.working;
    case PidRole:
        return session.pid;
    default:
        return {};
    }
}

QHash<int, QByteArray> AgentSessionModel::roleNames() const
{
    return {
        {SessionIdRole, "sessionId"},
        {KindRole, "kind"},
        {TitleRole, "title"},
        {AccountRole, "account"},
        {ProjectRole, "project"},
        {WorkingRole, "working"},
        {PidRole, "pid"},
    };
}

void AgentSessionModel::update(const QList<AgentSession> &live)
{
    QSet<QString> liveIds;
    for (const AgentSession &session : live) {
        liveIds.insert(session.id);
    }
    for (qsizetype row = m_sessions.size() - 1; row >= 0; --row) {
        if (!liveIds.contains(m_sessions.at(row).id)) {
            beginRemoveRows({}, int(row), int(row));
            m_sessions.removeAt(row);
            endRemoveRows();
        }
    }
    // What is left is an ordered subset of `live`: walk both, inserting the new rows.
    for (qsizetype row = 0; row < live.size(); ++row) {
        const AgentSession &session = live.at(row);
        if (row >= m_sessions.size() || m_sessions.at(row).id != session.id) {
            beginInsertRows({}, int(row), int(row));
            m_sessions.insert(row, session);
            endInsertRows();
        } else if (!(m_sessions.at(row) == session)) {
            m_sessions[row] = session;
            const QModelIndex changed = index(int(row));
            Q_EMIT dataChanged(changed, changed);
        }
    }
}

AgentMonitor::AgentMonitor(QObject *parent)
    : QObject(parent)
    , m_model(this)
{
    m_timer.setInterval(refreshInterval);
    connect(&m_timer, &QTimer::timeout, this, &AgentMonitor::refresh);
    // After the integrator's settings Bindings have landed.
    QTimer::singleShot(0, this, &AgentMonitor::refresh);
}

void AgentMonitor::setClaudeEnabled(bool enabled)
{
    if (m_claudeEnabled == enabled) {
        return;
    }
    m_claudeEnabled = enabled;
    Q_EMIT claudeEnabledChanged();
    refresh();
}

void AgentMonitor::setOmpEnabled(bool enabled)
{
    if (m_ompEnabled == enabled) {
        return;
    }
    m_ompEnabled = enabled;
    Q_EMIT ompEnabledChanged();
    refresh();
}

int AgentMonitor::workingCount() const
{
    int working = 0;
    for (const AgentSession &session : m_model.sessions()) {
        working += session.working ? 1 : 0;
    }
    return working;
}

QStringList AgentMonitor::kinds() const
{
    bool claude = false;
    bool omp = false;
    for (const AgentSession &session : m_model.sessions()) {
        claude |= session.kind == claudeKind;
        omp |= session.kind == ompKind;
    }
    QStringList list;
    if (claude) {
        list << claudeKind;
    }
    if (omp) {
        list << ompKind;
    }
    return list;
}

QStringList AgentMonitor::workingKinds() const
{
    bool claude = false;
    bool omp = false;
    for (const AgentSession &session : m_model.sessions()) {
        claude |= session.working && session.kind == claudeKind;
        omp |= session.working && session.kind == ompKind;
    }
    QStringList list;
    if (claude) {
        list << claudeKind;
    }
    if (omp) {
        list << ompKind;
    }
    return list;
}

void AgentMonitor::refresh()
{
    const bool claude = m_claudeEnabled;
    const bool omp = m_ompEnabled;
    if (!claude && !omp) {
        // Nothing to watch: no timer, no scans; a scan in flight is discarded by apply().
        m_timer.stop();
        m_rescan = false;
        apply({});
        return;
    }
    if (!m_timer.isActive()) {
        m_timer.start();
    }
    if (m_scanning) {
        m_rescan = true;
        return;
    }
    m_scanning = true;
    auto titles = m_titles;
    (void)QtConcurrent::run([claude, omp, titles] {
        QList<AgentSession> found;
        if (claude) {
            found += AgentScan::claudeSessions(*titles);
        } else {
            titles->entries.clear();
        }
        if (omp) {
            found += AgentScan::ompSessions();
        }
        return found;
    }).then(this, [this](QList<AgentSession> found) {
        m_scanning = false;
        apply(std::move(found));
        if (m_rescan) {
            m_rescan = false;
            refresh();
        }
    });
}

void AgentMonitor::apply(QList<AgentSession> found)
{
    // Settings may have changed while the scan ran.
    found.removeIf([this](const AgentSession &session) {
        return session.kind == claudeKind ? !m_claudeEnabled : !m_ompEnabled;
    });
    const QList<AgentSession> &current = m_model.sessions();
    if (current == found) {
        return;
    }
    QSet<QString> wasWorking;
    for (const AgentSession &session : current) {
        if (session.working) {
            wasWorking.insert(session.id);
        }
    }
    QStringList done;
    for (const AgentSession &session : found) {
        if (!session.working && wasWorking.contains(session.id)) {
            done << session.kind;
        }
    }
    m_model.update(found);
    Q_EMIT sessionsChanged();
    for (const QString &kind : std::as_const(done)) {
        Q_EMIT finished(kind);
    }
}

void AgentMonitor::focus(const QString &sessionId)
{
    qint64 pid = 0;
    for (const AgentSession &session : m_model.sessions()) {
        if (session.id == sessionId) {
            pid = session.pid;
            break;
        }
    }
    if (pid <= 1) {
        return;
    }
    (void)QtConcurrent::run([pid] { return AgentFocus::prepare(pid); }).then(this, [](const QString &script) {
        if (!script.isEmpty()) {
            KWinScript::runOnce(script);
        }
    });
}
