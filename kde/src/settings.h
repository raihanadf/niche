#pragma once

#include <QObject>
#include <QRectF>
#include <QSettings>
#include <QStringList>
#include <QUrl>

// Plain getter/setter pair over QSettings; the Q_PROPERTY and signal stay
// spelled out so moc sees them.
#define NICHE_SETTING(type, name, setter, key, fallback)                                                                                                       \
    type name() const                                                                                                                                          \
    {                                                                                                                                                          \
        return m_store.value(QStringLiteral(key), QVariant::fromValue<type>(fallback)).value<type>();                                                          \
    }                                                                                                                                                          \
    void setter(const type &value)                                                                                                                             \
    {                                                                                                                                                          \
        if (name() == value)                                                                                                                                   \
            return;                                                                                                                                            \
        m_store.setValue(QStringLiteral(key), QVariant::fromValue<type>(value));                                                                               \
        Q_EMIT name##Changed();                                                                                                                                \
    }

// Persistent preferences (~/.config/niche-kde/niche-kde.conf) plus the idle
// picture. Backends never read this; Main.qml binds each value onto the
// backend property it controls.
class Settings : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool showInTray READ showInTray WRITE setShowInTray NOTIFY showInTrayChanged)
    Q_PROPERTY(bool liveVisualizer READ liveVisualizer WRITE setLiveVisualizer NOTIFY liveVisualizerChanged)
    Q_PROPERTY(bool showAgents READ showAgents WRITE setShowAgents NOTIFY showAgentsChanged)
    Q_PROPERTY(bool showClaude READ showClaude WRITE setShowClaude NOTIFY showClaudeChanged)
    Q_PROPERTY(bool showOmp READ showOmp WRITE setShowOmp NOTIFY showOmpChanged)
    Q_PROPERTY(bool clipboardOn READ clipboardOn WRITE setClipboardOn NOTIFY clipboardOnChanged)
    Q_PROPERTY(int clipboardLimit READ clipboardLimit WRITE setClipboardLimit NOTIFY clipboardLimitChanged)
    Q_PROPERTY(bool clipboardShortcut READ clipboardShortcut WRITE setClipboardShortcut NOTIFY clipboardShortcutChanged)
    Q_PROPERTY(bool pastesOnPick READ pastesOnPick WRITE setPastesOnPick NOTIFY pastesOnPickChanged)
    Q_PROPERTY(bool showLockIndicator READ showLockIndicator WRITE setShowLockIndicator NOTIFY showLockIndicatorChanged)
    Q_PROPERTY(bool activitiesOn READ activitiesOn WRITE setActivitiesOn NOTIFY activitiesOnChanged)
    Q_PROPERTY(QStringList disabledActivities READ disabledActivities WRITE setDisabledActivities NOTIFY disabledActivitiesChanged)
    Q_PROPERTY(bool openAtLogin READ openAtLogin WRITE setOpenAtLogin NOTIFY openAtLoginChanged)
    Q_PROPERTY(QStringList builtInArt READ builtInArt CONSTANT)
    Q_PROPERTY(QString idleBuiltIn READ idleBuiltIn NOTIFY idleArtChanged)
    Q_PROPERTY(QUrl idleArt READ idleArt NOTIFY idleArtChanged)
    Q_PROPERTY(QRectF idleArtCrop READ idleArtCrop NOTIFY idleArtChanged)
    Q_PROPERTY(QString version READ version CONSTANT)

public:
    explicit Settings(QObject *parent = nullptr);

    NICHE_SETTING(bool, showInTray, setShowInTray, "general/showInTray", true)
    NICHE_SETTING(bool, liveVisualizer, setLiveVisualizer, "music/liveVisualizer", false)
    NICHE_SETTING(bool, showAgents, setShowAgents, "agents/show", true)
    NICHE_SETTING(bool, showClaude, setShowClaude, "agents/claude", true)
    NICHE_SETTING(bool, showOmp, setShowOmp, "agents/omp", true)
    NICHE_SETTING(bool, clipboardOn, setClipboardOn, "clipboard/on", true)
    NICHE_SETTING(int, clipboardLimit, setClipboardLimit, "clipboard/limit", 10)
    NICHE_SETTING(bool, clipboardShortcut, setClipboardShortcut, "clipboard/shortcut", true)
    NICHE_SETTING(bool, pastesOnPick, setPastesOnPick, "clipboard/pastesOnPick", true)
    NICHE_SETTING(bool, showLockIndicator, setShowLockIndicator, "lock/show", true)
    NICHE_SETTING(bool, activitiesOn, setActivitiesOn, "activities/on", true)
    NICHE_SETTING(QStringList, disabledActivities, setDisabledActivities, "activities/disabled", QStringList())

    bool openAtLogin() const;
    void setOpenAtLogin(bool on);

    QStringList builtInArt() const;
    // Name of the chosen built-in picture, or empty.
    QString idleBuiltIn() const;
    // The picture shown in the empty island, or an empty url.
    QUrl idleArt() const;
    // Square around the picture's opaque pixels, normalized to 0..1 of the
    // image, so transparent margins are trimmed like niche does.
    QRectF idleArtCrop() const;
    QString version() const;

    Q_INVOKABLE static QUrl builtInUrl(const QString &name);
    Q_INVOKABLE static QRectF cropFor(const QUrl &url);
    Q_INVOKABLE void setIdleBuiltIn(const QString &name);
    // Copies the file into the data dir; false when it isn't a readable image.
    Q_INVOKABLE bool setIdleImage(const QUrl &file);
    Q_INVOKABLE void clearIdleImage();
    Q_INVOKABLE void toggleActivity(const QString &kind, bool on);

Q_SIGNALS:
    void showInTrayChanged();
    void liveVisualizerChanged();
    void showAgentsChanged();
    void showClaudeChanged();
    void showOmpChanged();
    void clipboardOnChanged();
    void clipboardLimitChanged();
    void clipboardShortcutChanged();
    void pastesOnPickChanged();
    void showLockIndicatorChanged();
    void activitiesOnChanged();
    void disabledActivitiesChanged();
    void openAtLoginChanged();
    void idleArtChanged();

private:
    void loadIdleArt();
    void removeIdleCopy();
    static QString artFolder();
    static QString autostartFile();

    QSettings m_store;
    QUrl m_idleArt;
    QRectF m_idleCrop;
};

#undef NICHE_SETTING
