#pragma once

#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <optional>

class QDBusMessage;

// Watches BlueZ audio devices (Linux counterpart of niche's HeadphonesWatcher
// in Headphones.swift). Connect/disconnect come from org.bluez.Device1
// "Connected", battery from org.bluez.Battery1 "Percentage"; everything is
// signal driven, no polling.
class HeadphonesWatcher : public QObject
{
    Q_OBJECT

public:
    explicit HeadphonesWatcher(QObject *parent = nullptr);
    ~HeadphonesWatcher() override;

    void start();
    void stop();

    // Breeze icon for a device, like niche's HeadphonesWatcher.symbol(for:).
    static QString iconFor(const QString &name, const QString &bluezIcon);

Q_SIGNALS:
    // level is 0..1, or < 0 when the device reports no battery.
    void connected(const QString &name, const QString &icon, double level);
    void disconnected(const QString &name, const QString &icon);
    void lowBattery(const QString &name, const QString &icon, double level);

private Q_SLOTS:
    void onInterfacesAdded(const QDBusMessage &message);
    void onInterfacesRemoved(const QDBusMessage &message);
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated, const QDBusMessage &message);

private:
    struct Device {
        QString name;
        QString icon;
        quint32 deviceClass = 0;
        bool connected = false;
        std::optional<double> battery;
    };

    void loadManagedObjects();
    void applyInterfaces(const QString &path, const QMap<QString, QVariantMap> &interfaces, bool initial);
    void applyDevice(const QString &path, const QVariantMap &properties, bool initial);
    void applyBattery(const QString &path, const QVariantMap &properties);
    void track(const QString &path, bool initial);
    void forget(const QString &path);
    void finishConnect(const QString &path);
    bool isAudio(const Device &device) const;
    QString nameOf(const Device &device) const;

    bool m_running = false;
    quint64 m_generation = 0;
    QElapsedTimer m_startedAt;
    QHash<QString, Device> m_devices;
    QSet<QString> m_tracked;
    // Connected devices waiting (up to 3 s) for their battery level before the
    // connect popup; value: connected during the launch grace period.
    QHash<QString, bool> m_pending;
};
