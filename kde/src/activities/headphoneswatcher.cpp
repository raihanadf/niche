#include "activities/headphoneswatcher.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QTimer>

namespace
{
const QString Service = QStringLiteral("org.bluez");
const QString DeviceInterface = QStringLiteral("org.bluez.Device1");
const QString BatteryInterface = QStringLiteral("org.bluez.Battery1");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");
const QString ObjectManagerInterface = QStringLiteral("org.freedesktop.DBus.ObjectManager");

// niche waits up to 6 × 0.5 s for the battery level before announcing a connect,
// and treats connects within 2 s of start as already-connected devices.
constexpr int BatteryWaitMs = 3000;
constexpr qint64 LaunchGraceMs = 2000;

QVariant unwrap(const QVariant &value)
{
    if (value.canConvert<QDBusVariant>() && value.userType() == qMetaTypeId<QDBusVariant>()) {
        return value.value<QDBusVariant>().variant();
    }
    return value;
}

QMap<QString, QVariantMap> interfacesFrom(const QVariant &value)
{
    QMap<QString, QVariantMap> interfaces;
    if (value.userType() == qMetaTypeId<QDBusArgument>()) {
        const QDBusArgument argument = value.value<QDBusArgument>();
        argument >> interfaces;
    }
    return interfaces;
}
}

HeadphonesWatcher::HeadphonesWatcher(QObject *parent)
    : QObject(parent)
{
}

HeadphonesWatcher::~HeadphonesWatcher()
{
    stop();
}

QString HeadphonesWatcher::iconFor(const QString &name, const QString &bluezIcon)
{
    const QString lower = name.toLower();
    if (lower.contains(QLatin1String("max"))) {
        return QStringLiteral("audio-headphones-symbolic");
    }
    if (lower.contains(QLatin1String("airpods")) || lower.contains(QLatin1String("buds")) || bluezIcon == QLatin1String("audio-headset")) {
        return QStringLiteral("audio-headset-symbolic");
    }
    return QStringLiteral("audio-headphones-symbolic");
}

void HeadphonesWatcher::start()
{
    if (m_running) {
        return;
    }
    m_running = true;
    ++m_generation;
    m_startedAt.start();

    QDBusConnection bus = QDBusConnection::systemBus();
    bus.connect(Service, QStringLiteral("/"), ObjectManagerInterface, QStringLiteral("InterfacesAdded"), this, SLOT(onInterfacesAdded(QDBusMessage)));
    bus.connect(Service, QStringLiteral("/"), ObjectManagerInterface, QStringLiteral("InterfacesRemoved"), this, SLOT(onInterfacesRemoved(QDBusMessage)));
    // Filter on the bus so MediaTransport/MediaPlayer chatter never wakes us.
    for (const QString &interface : {DeviceInterface, BatteryInterface}) {
        bus.connect(Service,
                    QString(),
                    PropertiesInterface,
                    QStringLiteral("PropertiesChanged"),
                    QStringList{interface},
                    QStringLiteral("sa{sv}as"),
                    this,
                    SLOT(onPropertiesChanged(QString, QVariantMap, QStringList, QDBusMessage)));
    }
    loadManagedObjects();
}

void HeadphonesWatcher::stop()
{
    if (!m_running) {
        return;
    }
    m_running = false;
    ++m_generation;

    QDBusConnection bus = QDBusConnection::systemBus();
    bus.disconnect(Service, QStringLiteral("/"), ObjectManagerInterface, QStringLiteral("InterfacesAdded"), this, SLOT(onInterfacesAdded(QDBusMessage)));
    bus.disconnect(Service, QStringLiteral("/"), ObjectManagerInterface, QStringLiteral("InterfacesRemoved"), this, SLOT(onInterfacesRemoved(QDBusMessage)));
    for (const QString &interface : {DeviceInterface, BatteryInterface}) {
        bus.disconnect(Service,
                       QString(),
                       PropertiesInterface,
                       QStringLiteral("PropertiesChanged"),
                       QStringList{interface},
                       QStringLiteral("sa{sv}as"),
                       this,
                       SLOT(onPropertiesChanged(QString, QVariantMap, QStringList, QDBusMessage)));
    }
    m_devices.clear();
    m_tracked.clear();
    m_pending.clear();
}

void HeadphonesWatcher::loadManagedObjects()
{
    const QDBusMessage call = QDBusMessage::createMethodCall(Service, QStringLiteral("/"), ObjectManagerInterface, QStringLiteral("GetManagedObjects"));
    auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::systemBus().asyncCall(call), this);
    const quint64 generation = m_generation;
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, generation](QDBusPendingCallWatcher *watcher) {
        watcher->deleteLater();
        const QDBusMessage reply = watcher->reply();
        if (generation != m_generation || reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
            return;
        }
        const QVariant value = reply.arguments().constFirst();
        if (value.userType() != qMetaTypeId<QDBusArgument>()) {
            return;
        }
        const QDBusArgument argument = value.value<QDBusArgument>();
        argument.beginMap();
        while (!argument.atEnd()) {
            QDBusObjectPath path;
            QMap<QString, QVariantMap> interfaces;
            argument.beginMapEntry();
            argument >> path >> interfaces;
            argument.endMapEntry();
            applyInterfaces(path.path(), interfaces, true);
        }
        argument.endMap();
    });
}

void HeadphonesWatcher::onInterfacesAdded(const QDBusMessage &message)
{
    const QList<QVariant> arguments = message.arguments();
    if (arguments.size() < 2) {
        return;
    }
    const QString path = arguments.at(0).value<QDBusObjectPath>().path();
    applyInterfaces(path, interfacesFrom(arguments.at(1)), false);
}

void HeadphonesWatcher::onInterfacesRemoved(const QDBusMessage &message)
{
    const QList<QVariant> arguments = message.arguments();
    if (arguments.size() < 2) {
        return;
    }
    const QString path = arguments.at(0).value<QDBusObjectPath>().path();
    const QStringList interfaces = arguments.at(1).toStringList();
    if (interfaces.contains(DeviceInterface)) {
        forget(path);
        m_devices.remove(path);
    } else if (interfaces.contains(BatteryInterface)) {
        if (auto it = m_devices.find(path); it != m_devices.end()) {
            it->battery.reset();
        }
    }
}

void HeadphonesWatcher::onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated, const QDBusMessage &message)
{
    Q_UNUSED(invalidated)
    const QString path = message.path();
    if (interface == DeviceInterface) {
        if (!m_devices.contains(path)) {
            // A device we have not seen yet: fetch everything so we know
            // whether it is an audio device before acting on "Connected".
            QDBusMessage call = QDBusMessage::createMethodCall(Service, path, PropertiesInterface, QStringLiteral("GetAll"));
            call << DeviceInterface;
            auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::systemBus().asyncCall(call), this);
            const quint64 generation = m_generation;
            connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, generation, path](QDBusPendingCallWatcher *watcher) {
                watcher->deleteLater();
                QDBusPendingReply<QVariantMap> reply = *watcher;
                if (generation != m_generation || reply.isError()) {
                    return;
                }
                applyDevice(path, reply.value(), false);
            });
            return;
        }
        applyDevice(path, changed, false);
    } else if (interface == BatteryInterface) {
        applyBattery(path, changed);
    }
}

void HeadphonesWatcher::applyInterfaces(const QString &path, const QMap<QString, QVariantMap> &interfaces, bool initial)
{
    if (auto it = interfaces.constFind(DeviceInterface); it != interfaces.constEnd()) {
        applyDevice(path, it.value(), initial);
    }
    if (auto it = interfaces.constFind(BatteryInterface); it != interfaces.constEnd()) {
        applyBattery(path, it.value());
    }
}

void HeadphonesWatcher::applyDevice(const QString &path, const QVariantMap &properties, bool initial)
{
    Device &device = m_devices[path];
    if (auto it = properties.constFind(QStringLiteral("Alias")); it != properties.constEnd()) {
        device.name = unwrap(it.value()).toString();
    } else if (auto name = properties.constFind(QStringLiteral("Name")); name != properties.constEnd() && device.name.isEmpty()) {
        device.name = unwrap(name.value()).toString();
    }
    if (auto it = properties.constFind(QStringLiteral("Icon")); it != properties.constEnd()) {
        device.icon = unwrap(it.value()).toString();
    }
    if (auto it = properties.constFind(QStringLiteral("Class")); it != properties.constEnd()) {
        device.deviceClass = unwrap(it.value()).toUInt();
    }
    if (auto it = properties.constFind(QStringLiteral("Connected")); it != properties.constEnd()) {
        device.connected = unwrap(it.value()).toBool();
        if (device.connected) {
            track(path, initial);
        } else {
            forget(path);
        }
    }
}

void HeadphonesWatcher::applyBattery(const QString &path, const QVariantMap &properties)
{
    auto it = properties.constFind(QStringLiteral("Percentage"));
    if (it == properties.constEnd()) {
        return;
    }
    const double level = qBound(0.0, unwrap(it.value()).toUInt() / 100.0, 1.0);
    Device &device = m_devices[path];
    const double last = device.battery.value_or(1.0);
    device.battery = level;

    if (m_pending.contains(path)) {
        finishConnect(path);
        return;
    }
    if (!m_tracked.contains(path) || level <= 0) {
        return;
    }
    if ((last > 0.2 && level <= 0.2) || (last > 0.1 && level <= 0.1)) {
        Q_EMIT lowBattery(nameOf(device), iconFor(nameOf(device), device.icon), level);
    }
}

bool HeadphonesWatcher::isAudio(const Device &device) const
{
    // Major device class 0x04 = Audio/Video (niche: kBluetoothDeviceClassMajorAudio).
    // LE audio devices carry no class, only an "audio-*" icon.
    return ((device.deviceClass >> 8) & 0x1F) == 0x04 || device.icon.startsWith(QLatin1String("audio-"));
}

QString HeadphonesWatcher::nameOf(const Device &device) const
{
    return device.name;
}

void HeadphonesWatcher::track(const QString &path, bool initial)
{
    auto it = m_devices.constFind(path);
    if (it == m_devices.constEnd() || !isAudio(it.value()) || m_tracked.contains(path)) {
        return;
    }
    m_tracked.insert(path);
    const bool isLaunch = initial || m_startedAt.elapsed() < LaunchGraceMs;
    m_pending.insert(path, isLaunch);
    if (it->battery) {
        finishConnect(path);
        return;
    }
    const quint64 generation = m_generation;
    QTimer::singleShot(BatteryWaitMs, this, [this, generation, path] {
        if (generation == m_generation) {
            finishConnect(path);
        }
    });
}

void HeadphonesWatcher::finishConnect(const QString &path)
{
    auto pending = m_pending.find(path);
    if (pending == m_pending.end()) {
        return;
    }
    const bool isLaunch = pending.value();
    m_pending.erase(pending);
    if (!m_tracked.contains(path) || isLaunch) {
        return;
    }
    const Device &device = m_devices[path];
    Q_EMIT connected(nameOf(device), iconFor(nameOf(device), device.icon), device.battery.value_or(-1.0));
}

void HeadphonesWatcher::forget(const QString &path)
{
    if (!m_tracked.remove(path)) {
        return;
    }
    m_pending.remove(path);
    auto it = m_devices.find(path);
    if (it == m_devices.end()) {
        return;
    }
    it->battery.reset();
    Q_EMIT disconnected(nameOf(it.value()), iconFor(nameOf(it.value()), it->icon));
}
