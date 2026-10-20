#pragma once

#include "agents/agentscan.h"

#include <QAbstractListModel>
#include <QObject>
#include <QStringList>
#include <QTimer>

#include <memory>

// Live sessions for QML, in niche's order (claude sessions, then omp, each by id).
class AgentSessionModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Role {
        SessionIdRole = Qt::UserRole + 1,
        KindRole,
        TitleRole,
        AccountRole,
        ProjectRole,
        WorkingRole,
        PidRole,
    };
    Q_ENUM(Role)

    explicit AgentSessionModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    const QList<AgentSession> &sessions() const { return m_sessions; }

    // Row-level diff (both lists are sorted by id) so QML can animate rows in/out.
    void update(const QList<AgentSession> &live);

private:
    QList<AgentSession> m_sessions;
};

// niche's AgentMonitor: Claude Code and omp sessions running on this machine.
class AgentMonitor : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool claudeEnabled READ claudeEnabled WRITE setClaudeEnabled NOTIFY claudeEnabledChanged)
    Q_PROPERTY(bool ompEnabled READ ompEnabled WRITE setOmpEnabled NOTIFY ompEnabledChanged)
    Q_PROPERTY(int count READ count NOTIFY sessionsChanged)
    Q_PROPERTY(bool empty READ empty NOTIFY sessionsChanged)
    Q_PROPERTY(int workingCount READ workingCount NOTIFY sessionsChanged)
    Q_PROPERTY(QStringList kinds READ kinds NOTIFY sessionsChanged)
    Q_PROPERTY(QStringList workingKinds READ workingKinds NOTIFY sessionsChanged)
    Q_PROPERTY(QAbstractItemModel *model READ model CONSTANT)

public:
    explicit AgentMonitor(QObject *parent = nullptr);

    bool claudeEnabled() const { return m_claudeEnabled; }
    void setClaudeEnabled(bool enabled);
    bool ompEnabled() const { return m_ompEnabled; }
    void setOmpEnabled(bool enabled);

    int count() const { return int(m_model.sessions().size()); }
    bool empty() const { return m_model.sessions().isEmpty(); }
    int workingCount() const;
    // Kinds with live sessions, in order claude, omp.
    QStringList kinds() const;
    // Kinds with at least one working session, in order claude, omp.
    QStringList workingKinds() const;
    QAbstractItemModel *model() { return &m_model; }

    // Switches tmux / the terminal tab to the session and raises its window.
    Q_INVOKABLE void focus(const QString &sessionId);

Q_SIGNALS:
    void claudeEnabledChanged();
    void ompEnabledChanged();
    void sessionsChanged();
    // A session went from working to paused.
    void finished(const QString &kind);

private:
    void refresh();
    void apply(QList<AgentSession> found);

    AgentSessionModel m_model;
    QTimer m_timer;
    bool m_claudeEnabled = true;
    bool m_ompEnabled = true;
    bool m_scanning = false;
    bool m_rescan = false;
    // Touched only by the single in-flight scan.
    std::shared_ptr<AgentScan::TitleCache> m_titles = std::make_shared<AgentScan::TitleCache>();
};
