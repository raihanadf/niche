#pragma once

#include <QColor>
#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

#include <memory>
#include <optional>
#include <utility>
#include <vector>

class HeadphonesWatcher;

// Moments: short live activities shown in the pill (niche's LiveActivityCenter,
// LiveActivities.swift). One activity at a time; a new one replaces the
// current one immediately and restarts its timer, exactly like niche.
class LiveActivities : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ isOn WRITE setOn NOTIFY enabledChanged)
    Q_PROPERTY(QStringList disabledKinds READ disabledKinds WRITE setDisabledKinds NOTIFY disabledKindsChanged)
    Q_PROPERTY(bool replacesSystemHUD READ replacesSystemHUD WRITE setReplacesSystemHUD NOTIFY replacesSystemHUDChanged)
    Q_PROPERTY(bool shellRestartPending READ shellRestartPending NOTIFY shellRestartPendingChanged)
    Q_PROPERTY(bool suppressVolume READ suppressVolume WRITE setSuppressVolume NOTIFY suppressVolumeChanged)

    Q_PROPERTY(QString kind READ kind NOTIFY activityChanged)
    Q_PROPERTY(bool showing READ showing NOTIFY showingChanged)
    Q_PROPERTY(qreal value READ value NOTIFY activityChanged)
    Q_PROPERTY(bool isOn READ activityIsOn NOTIFY activityChanged)
    Q_PROPERTY(QString text READ text NOTIFY activityChanged)
    Q_PROPERTY(QString detail READ detail NOTIFY activityChanged)
    Q_PROPERTY(QString iconName READ iconName NOTIFY activityChanged)
    Q_PROPERTY(QUrl image READ image NOTIFY activityChanged)
    Q_PROPERTY(bool hasColor READ hasColor NOTIFY activityChanged)
    Q_PROPERTY(QColor color READ color NOTIFY activityChanged)
    Q_PROPERTY(qreal extraWidth READ extraWidth NOTIFY activityChanged)

public:
    explicit LiveActivities(QObject *parent = nullptr);
    ~LiveActivities() override;

    bool isOn() const { return m_on; }
    void setOn(bool on);
    QStringList disabledKinds() const { return m_disabled; }
    void setDisabledKinds(const QStringList &kinds);
    bool replacesSystemHUD() const { return m_replacesHUD; }
    void setReplacesSystemHUD(bool replaces);
    bool shellRestartPending() const { return m_restartPending; }
    bool suppressVolume() const { return m_suppressVolume; }
    void setSuppressVolume(bool suppress);

    QString kind() const { return m_current.kind; }
    bool showing() const { return m_showing; }
    qreal value() const { return m_current.level; }
    bool activityIsOn() const { return m_current.isOn; }
    QString text() const { return m_current.text; }
    QString detail() const { return m_current.detail; }
    QString iconName() const { return m_current.iconName; }
    QUrl image() const { return m_current.image; }
    bool hasColor() const { return m_current.color.isValid(); }
    QColor color() const { return m_current.color; }
    qreal extraWidth() const;

    Q_INVOKABLE bool isEnabled(const QString &kind) const;
    Q_INVOKABLE void setEnabled(const QString &kind, bool on);
    Q_INVOKABLE QVariantList kinds() const;
    Q_INVOKABLE void restartPlasmaShell();

public Q_SLOTS:
    // Called by the integrator from AudioOutput::adjusted().
    void showVolume(qreal level, bool muted);
    // Called by the integrator from AgentMonitor::finished(kind).
    void agentFinished(const QString &kind);
    // Called by the integrator when something lands on the clipboard.
    // kind: text|link|color|image|files; image/color empty when not relevant.
    void copied(const QString &kind, const QString &text, const QUrl &image, const QColor &color);

Q_SIGNALS:
    void enabledChanged();
    void disabledKindsChanged();
    void replacesSystemHUDChanged();
    void shellRestartPendingChanged();
    void suppressVolumeChanged();
    void activityChanged();
    void showingChanged();

private Q_SLOTS:
    void onNotificationProperties(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);
    void onBrightnessChanged(const QString &display, int brightness, const QString &sourceClient, const QString &sourceContext);
    void onBrightnessRangeChanged(const QString &display, int maxBrightness, int brightness);
    void onDisplayAdded(const QString &display);
    void onDisplayRemoved(const QString &display);
    void onUPowerDeviceProperties(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);
    void onUPowerProperties(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);

private:
    struct Activity {
        QString kind;
        double level = 0;
        bool isOn = false;
        QString text;
        QString detail;
        QString iconName;
        QUrl image;
        QColor color;
    };

    struct Display {
        int max = -1;
        int brightness = -1;
        bool internal = false;
        bool loaded = false;
        bool loading = false;
        bool showWhenLoaded = false;
    };

    struct Battery {
        int level;
        bool onAC;
        bool full;
    };

    bool watching(const QString &kind) const;
    void scheduleRestart();
    void restart();
    void stopSources();

    void show(const Activity &activity, double seconds);
    void hide();
    void clear();

    // Caps Lock: keyboard LEDs in sysfs.
    void scanCapsLeds();
    void readCaps();

    // Do Not Disturb: org.freedesktop.Notifications "Inhibited".
    void startFocus();
    void stopFocus();
    void focusChanged(bool active);

    // Brightness: org.kde.ScreenBrightness (powerdevil).
    void startBrightness();
    void stopBrightness();
    void loadDisplay(const QString &display);
    QString preferredDisplay() const;
    void brightnessChanged(const QString &display);

    // Battery: UPower DisplayDevice + OnBattery.
    void startBattery();
    void stopBattery();
    void readBattery();

    // Headphones: BlueZ.
    void startHeadphones();
    void stopHeadphones();

    bool m_on = true;
    QStringList m_disabled;
    bool m_replacesHUD = false;
    bool m_restartPending = false;
    // What plasmashell is running with (the file value when we started or
    // when we last restarted it).
    bool m_shellReplacesHUD = false;
    bool m_suppressVolume = false;

    Activity m_current;
    bool m_showing = false;
    QTimer m_hideTimer;
    QTimer m_clearTimer;
    QTimer m_restartTimer;
    quint64 m_generation = 0;

    QTimer m_capsTimer;
    std::vector<std::unique_ptr<QFile>> m_capsLeds;
    int m_capsTicks = 0;
    std::optional<bool> m_lastCaps;

    bool m_focusWatching = false;
    std::optional<bool> m_lastFocus;

    bool m_brightnessWatching = false;
    QStringList m_displayOrder;
    QHash<QString, Display> m_displays;
    std::optional<double> m_lastBrightness;

    bool m_batteryWatching = false;
    QTimer m_batteryTimer;
    bool m_haveDevice = false;
    bool m_haveRoot = false;
    double m_percentage = 0;
    uint m_batteryState = 0;
    uint m_batteryType = 0;
    bool m_batteryPresent = false;
    bool m_onBattery = false;
    std::optional<Battery> m_lastBattery;

    std::optional<std::pair<double, bool>> m_lastVolume;

    HeadphonesWatcher *m_headphones = nullptr;
};
