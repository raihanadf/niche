#include "activities/liveactivities.h"

#include "activities/headphoneswatcher.h"
#include "activities/plasmaosd.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QDir>

#include <cmath>
#include <cstdlib>
#include <iterator>
#include <utility>

namespace
{
// niche's LiveActivityCenter.Kind, in order. noiseControl has no Linux source
// (AirPods listening modes are not exposed by BlueZ), so it is left out.
struct KindInfo {
    const char *kind;
    const char *title;
};
constexpr KindInfo Kinds[] = {
    {"capsLock", "Caps Lock"},
    {"focus", "Do Not Disturb"},
    {"volume", "Volume"},
    {"brightness", "Brightness"},
    {"lowBattery", "Low battery"},
    {"charging", "Charging"},
    {"fullyCharged", "Fully charged"},
    {"headphones", "Headphones connected"},
    {"headphonesBattery", "Headphones low battery"},
    {"agentDone", "Agent finished"},
    {"copied", "Copied to clipboard"},
};

constexpr int LowBatteryThreshold = 20;
constexpr int CapsIntervalMs = 250;
constexpr int CapsRescanTicks = 40; // look for new keyboards every 10 s
constexpr int FadeOutMs = 250;

const QString NotificationsService = QStringLiteral("org.freedesktop.Notifications");
const QString NotificationsPath = QStringLiteral("/org/freedesktop/Notifications");
const QString BrightnessService = QStringLiteral("org.kde.ScreenBrightness");
const QString BrightnessPath = QStringLiteral("/org/kde/ScreenBrightness");
const QString BrightnessInterface = QStringLiteral("org.kde.ScreenBrightness");
const QString DisplayInterface = QStringLiteral("org.kde.ScreenBrightness.Display");
const QString UPowerService = QStringLiteral("org.freedesktop.UPower");
const QString UPowerPath = QStringLiteral("/org/freedesktop/UPower");
const QString UPowerDevicePath = QStringLiteral("/org/freedesktop/UPower/devices/DisplayDevice");
const QString UPowerDeviceInterface = QStringLiteral("org.freedesktop.UPower.Device");
const QString PropertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");
const QString PropertiesChanged = QStringLiteral("PropertiesChanged");

// UPower device constants.
constexpr uint UPowerTypeBattery = 2;
constexpr uint UPowerStateFullyCharged = 4;

QVariant unwrap(const QVariant &value)
{
    if (value.userType() == qMetaTypeId<QDBusVariant>()) {
        return value.value<QDBusVariant>().variant();
    }
    return value;
}

// Calls `method` asynchronously and hands the reply arguments to `handler`
// unless the call failed.
template<typename Handler>
void callAsync(const QDBusConnection &bus, const QDBusMessage &call, QObject *context, Handler handler)
{
    auto *watcher = new QDBusPendingCallWatcher(QDBusConnection(bus).asyncCall(call), context);
    QObject::connect(watcher, &QDBusPendingCallWatcher::finished, context, [handler = std::move(handler)](QDBusPendingCallWatcher *watcher) {
        watcher->deleteLater();
        const QDBusMessage reply = watcher->reply();
        if (reply.type() == QDBusMessage::ReplyMessage) {
            handler(reply.arguments());
        }
    });
}

QDBusMessage propertyGet(const QString &service, const QString &path, const QString &interface, const QString &name)
{
    QDBusMessage call = QDBusMessage::createMethodCall(service, path, PropertiesInterface, QStringLiteral("Get"));
    call << interface << name;
    return call;
}

QDBusMessage propertyGetAll(const QString &service, const QString &path, const QString &interface)
{
    QDBusMessage call = QDBusMessage::createMethodCall(service, path, PropertiesInterface, QStringLiteral("GetAll"));
    call << interface;
    return call;
}

QString percentText(double fraction)
{
    return QString::number(qRound(fraction * 100)) + QLatin1Char('%');
}

QString clipboardIcon(const QString &kind)
{
    // niche's LabState.symbol(for:) mapped to Breeze.
    if (kind == QLatin1String("link")) {
        return QStringLiteral("insert-link-symbolic");
    }
    if (kind == QLatin1String("color")) {
        return QStringLiteral("color-picker-symbolic");
    }
    if (kind == QLatin1String("image")) {
        return QStringLiteral("view-preview-symbolic");
    }
    if (kind == QLatin1String("files")) {
        return QStringLiteral("document-multiple-symbolic");
    }
    return QStringLiteral("format-justify-left-symbolic");
}
}

LiveActivities::LiveActivities(QObject *parent)
    : QObject(parent)
{
    m_hideTimer.setSingleShot(true);
    connect(&m_hideTimer, &QTimer::timeout, this, &LiveActivities::hide);
    m_clearTimer.setSingleShot(true);
    m_clearTimer.setInterval(FadeOutMs);
    connect(&m_clearTimer, &QTimer::timeout, this, &LiveActivities::clear);
    // Settings arrive through QML bindings right after construction; restart
    // once they have settled instead of once per property.
    m_restartTimer.setSingleShot(true);
    m_restartTimer.setInterval(0);
    connect(&m_restartTimer, &QTimer::timeout, this, &LiveActivities::restart);
    m_capsTimer.setInterval(CapsIntervalMs);
    connect(&m_capsTimer, &QTimer::timeout, this, &LiveActivities::readCaps);
    // UPower reports one change as several PropertiesChanged signals.
    m_batteryTimer.setSingleShot(true);
    m_batteryTimer.setInterval(200);
    connect(&m_batteryTimer, &QTimer::timeout, this, &LiveActivities::readBattery);

    m_replacesHUD = !PlasmaOsd::isEnabled();
    m_shellReplacesHUD = m_replacesHUD;

    scheduleRestart();
}

LiveActivities::~LiveActivities()
{
    stopSources();
    stopHeadphones();
}

void LiveActivities::setOn(bool on)
{
    if (m_on == on) {
        return;
    }
    m_on = on;
    Q_EMIT enabledChanged();
    scheduleRestart();
}

void LiveActivities::setDisabledKinds(const QStringList &kinds)
{
    if (m_disabled == kinds) {
        return;
    }
    m_disabled = kinds;
    Q_EMIT disabledKindsChanged();
    scheduleRestart();
}

void LiveActivities::setReplacesSystemHUD(bool replaces)
{
    if (m_replacesHUD == replaces) {
        return;
    }
    m_replacesHUD = replaces;
    Q_EMIT replacesSystemHUDChanged();
    PlasmaOsd::setEnabled(!replaces, this);
    const bool pending = m_replacesHUD != m_shellReplacesHUD;
    if (pending != m_restartPending) {
        m_restartPending = pending;
        Q_EMIT shellRestartPendingChanged();
    }
}

void LiveActivities::restartPlasmaShell()
{
    PlasmaOsd::restartShell();
    m_shellReplacesHUD = m_replacesHUD;
    if (m_restartPending) {
        m_restartPending = false;
        Q_EMIT shellRestartPendingChanged();
    }
}

void LiveActivities::setSuppressVolume(bool suppress)
{
    if (m_suppressVolume == suppress) {
        return;
    }
    m_suppressVolume = suppress;
    Q_EMIT suppressVolumeChanged();
}

qreal LiveActivities::extraWidth() const
{
    // niche's LiveActivityView.room(for:).
    const QString &kind = m_current.kind;
    if (kind == QLatin1String("volume") || kind == QLatin1String("brightness") || kind == QLatin1String("lowBattery") || kind == QLatin1String("charging")
        || kind == QLatin1String("fullyCharged")) {
        return 12;
    }
    if (kind == QLatin1String("headphonesBattery")) {
        return 16;
    }
    if (kind == QLatin1String("headphones")) {
        return m_current.isOn && m_current.level > 0 ? 16 : 0;
    }
    return 0;
}

bool LiveActivities::isEnabled(const QString &kind) const
{
    return !m_disabled.contains(kind);
}

void LiveActivities::setEnabled(const QString &kind, bool on)
{
    QStringList disabled = m_disabled;
    if (on) {
        disabled.removeAll(kind);
    } else if (!disabled.contains(kind)) {
        disabled.append(kind);
    }
    setDisabledKinds(disabled);
}

QVariantList LiveActivities::kinds() const
{
    QVariantList list;
    list.reserve(std::size(Kinds));
    for (const KindInfo &info : Kinds) {
        list.append(QVariantMap{{QStringLiteral("kind"), QString::fromLatin1(info.kind)}, {QStringLiteral("title"), QString::fromLatin1(info.title)}});
    }
    return list;
}

bool LiveActivities::watching(const QString &kind) const
{
    return m_on && isEnabled(kind);
}

void LiveActivities::scheduleRestart()
{
    m_restartTimer.start();
}

void LiveActivities::stopSources()
{
    ++m_generation;
    m_capsTimer.stop();
    m_capsLeds.clear();
    stopFocus();
    stopBrightness();
    stopBattery();
}

void LiveActivities::restart()
{
    stopSources();
    m_lastCaps.reset();
    m_lastFocus.reset();
    m_lastBrightness.reset();
    m_lastBattery.reset();
    m_lastVolume.reset();
    if (!m_current.kind.isEmpty() && !watching(m_current.kind)) {
        hide();
    }

    if (watching(QStringLiteral("capsLock"))) {
        scanCapsLeds();
        readCaps();
        m_capsTimer.start();
    }
    if (watching(QStringLiteral("focus"))) {
        startFocus();
    }
    if (watching(QStringLiteral("brightness"))) {
        startBrightness();
    }
    if (watching(QStringLiteral("lowBattery")) || watching(QStringLiteral("charging")) || watching(QStringLiteral("fullyCharged"))) {
        startBattery();
    }
    if (watching(QStringLiteral("headphones")) || watching(QStringLiteral("headphonesBattery"))) {
        startHeadphones();
    } else {
        stopHeadphones();
    }
}

// MARK: - Presentation

void LiveActivities::show(const Activity &activity, double seconds)
{
    m_clearTimer.stop();
    m_current = activity;
    Q_EMIT activityChanged();
    if (!m_showing) {
        m_showing = true;
        Q_EMIT showingChanged();
    }
    m_hideTimer.start(int(seconds * 1000));
}

void LiveActivities::hide()
{
    m_hideTimer.stop();
    if (m_showing) {
        m_showing = false;
        Q_EMIT showingChanged();
    }
    if (!m_current.kind.isEmpty()) {
        m_clearTimer.start();
    }
}

void LiveActivities::clear()
{
    m_current = Activity{};
    Q_EMIT activityChanged();
}

// MARK: - Slots fed by other slices

void LiveActivities::showVolume(qreal level, bool muted)
{
    if (!watching(QStringLiteral("volume"))) {
        return;
    }
    const std::pair<double, bool> now{qBound(0.0, double(level), 1.0), muted};
    const bool changed = !m_lastVolume || *m_lastVolume != now;
    m_lastVolume = now;
    if (!changed || m_suppressVolume) {
        return;
    }
    Activity activity;
    activity.kind = QStringLiteral("volume");
    activity.level = now.first;
    activity.isOn = !muted;
    activity.iconName = muted ? QStringLiteral("audio-volume-muted-symbolic") : QStringLiteral("audio-volume-high-symbolic");
    show(activity, 1.4);
}

void LiveActivities::agentFinished(const QString &kind)
{
    if (!watching(QStringLiteral("agentDone"))) {
        return;
    }
    Activity activity;
    activity.kind = QStringLiteral("agentDone");
    activity.detail = kind;
    show(activity, 2.5);
}

void LiveActivities::copied(const QString &kind, const QString &text, const QUrl &image, const QColor &color)
{
    if (!watching(QStringLiteral("copied"))) {
        return;
    }
    Activity activity;
    activity.kind = QStringLiteral("copied");
    activity.text = text.left(200);
    activity.detail = kind;
    activity.iconName = clipboardIcon(kind);
    activity.image = image;
    activity.color = color;
    show(activity, 1.6);
}

// MARK: - Caps Lock

void LiveActivities::scanCapsLeds()
{
    m_capsLeds.clear();
    m_capsTicks = 0;
    const QDir leds(QStringLiteral("/sys/class/leds"));
    const QStringList names = leds.entryList({QStringLiteral("*::capslock")}, QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString &name : names) {
        auto file = std::make_unique<QFile>(leds.filePath(name + QStringLiteral("/brightness")));
        if (file->open(QIODevice::ReadOnly | QIODevice::Unbuffered)) {
            m_capsLeds.push_back(std::move(file));
        }
    }
}

void LiveActivities::readCaps()
{
    if (++m_capsTicks >= CapsRescanTicks) {
        scanCapsLeds();
    }
    if (m_capsLeds.empty()) {
        return;
    }
    // KWin drives the LED of every keyboard; any lit LED means Caps Lock is on.
    bool caps = false;
    for (const auto &file : m_capsLeds) {
        if (!file->seek(0)) {
            continue;
        }
        char buffer[8];
        const qint64 size = file->read(buffer, sizeof(buffer) - 1);
        if (size > 0) {
            buffer[size] = '\0';
            if (std::atoi(buffer) > 0) {
                caps = true;
                break;
            }
        }
    }
    if (m_lastCaps && *m_lastCaps != caps) {
        Activity activity;
        activity.kind = QStringLiteral("capsLock");
        activity.isOn = caps;
        activity.text = caps ? QStringLiteral("On") : QStringLiteral("Off");
        show(activity, 1.4);
    }
    m_lastCaps = caps;
}

// MARK: - Do Not Disturb

void LiveActivities::startFocus()
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    m_focusWatching = bus.connect(NotificationsService,
                                  NotificationsPath,
                                  PropertiesInterface,
                                  PropertiesChanged,
                                  this,
                                  SLOT(onNotificationProperties(QString, QVariantMap, QStringList)));
    const quint64 generation = m_generation;
    callAsync(bus, propertyGet(NotificationsService, NotificationsPath, NotificationsService, QStringLiteral("Inhibited")), this, [this, generation](const QList<QVariant> &arguments) {
        // A change signal that raced the reply already set the baseline.
        if (generation != m_generation || arguments.isEmpty() || m_lastFocus) {
            return;
        }
        m_lastFocus = unwrap(arguments.constFirst()).toBool();
    });
}

void LiveActivities::stopFocus()
{
    if (!m_focusWatching) {
        return;
    }
    QDBusConnection::sessionBus().disconnect(NotificationsService,
                                             NotificationsPath,
                                             PropertiesInterface,
                                             PropertiesChanged,
                                             this,
                                             SLOT(onNotificationProperties(QString, QVariantMap, QStringList)));
    m_focusWatching = false;
}

void LiveActivities::onNotificationProperties(const QString &interface, const QVariantMap &changed, const QStringList &invalidated)
{
    Q_UNUSED(invalidated)
    if (interface != NotificationsService) {
        return;
    }
    if (auto it = changed.constFind(QStringLiteral("Inhibited")); it != changed.constEnd()) {
        focusChanged(unwrap(it.value()).toBool());
    }
}

void LiveActivities::focusChanged(bool active)
{
    if (m_lastFocus != active) {
        Activity activity;
        activity.kind = QStringLiteral("focus");
        activity.isOn = active;
        activity.text = active ? QStringLiteral("On") : QStringLiteral("Off");
        activity.iconName = QStringLiteral("notifications-disabled-symbolic");
        show(activity, 1.6);
    }
    m_lastFocus = active;
}

// MARK: - Brightness

void LiveActivities::startBrightness()
{
    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.connect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("BrightnessChanged"), this, SLOT(onBrightnessChanged(QString, int, QString, QString)));
    bus.connect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("BrightnessRangeChanged"), this, SLOT(onBrightnessRangeChanged(QString, int, int)));
    bus.connect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("DisplayAdded"), this, SLOT(onDisplayAdded(QString)));
    bus.connect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("DisplayRemoved"), this, SLOT(onDisplayRemoved(QString)));
    m_brightnessWatching = true;

    const quint64 generation = m_generation;
    callAsync(bus, propertyGet(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("DisplaysDBusNames")), this, [this, generation](const QList<QVariant> &arguments) {
        if (generation != m_generation || arguments.isEmpty()) {
            return;
        }
        const QStringList names = unwrap(arguments.constFirst()).toStringList();
        // Keep powerdevil's order; displays seen through signals meanwhile go last.
        QStringList order = names;
        for (const QString &name : std::as_const(m_displayOrder)) {
            if (!order.contains(name)) {
                order.append(name);
            }
        }
        m_displayOrder = order;
        for (const QString &name : names) {
            loadDisplay(name);
        }
    });
}

void LiveActivities::stopBrightness()
{
    if (!m_brightnessWatching) {
        return;
    }
    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.disconnect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("BrightnessChanged"), this, SLOT(onBrightnessChanged(QString, int, QString, QString)));
    bus.disconnect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("BrightnessRangeChanged"), this, SLOT(onBrightnessRangeChanged(QString, int, int)));
    bus.disconnect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("DisplayAdded"), this, SLOT(onDisplayAdded(QString)));
    bus.disconnect(BrightnessService, BrightnessPath, BrightnessInterface, QStringLiteral("DisplayRemoved"), this, SLOT(onDisplayRemoved(QString)));
    m_brightnessWatching = false;
    m_displayOrder.clear();
    m_displays.clear();
}

void LiveActivities::loadDisplay(const QString &display)
{
    Display &info = m_displays[display];
    if (info.loading || info.loaded) {
        return;
    }
    info.loading = true;
    const quint64 generation = m_generation;
    callAsync(QDBusConnection::sessionBus(),
              propertyGetAll(BrightnessService, BrightnessPath + QLatin1Char('/') + display, DisplayInterface),
              this,
              [this, generation, display](const QList<QVariant> &arguments) {
                  if (generation != m_generation || arguments.isEmpty()) {
                      return;
                  }
                  auto it = m_displays.find(display);
                  if (it == m_displays.end()) {
                      return;
                  }
                  const QVariantMap properties = qdbus_cast<QVariantMap>(arguments.constFirst());
                  it->max = unwrap(properties.value(QStringLiteral("MaxBrightness"))).toInt();
                  it->brightness = unwrap(properties.value(QStringLiteral("Brightness"))).toInt();
                  it->internal = unwrap(properties.value(QStringLiteral("IsInternal"))).toBool();
                  it->loading = false;
                  it->loaded = true;
                  const bool showNow = it->showWhenLoaded;
                  it->showWhenLoaded = false;
                  if (preferredDisplay() != display || it->max <= 0) {
                      return;
                  }
                  if (showNow) {
                      brightnessChanged(display);
                  } else if (!m_lastBrightness) {
                      m_lastBrightness = double(it->brightness) / it->max;
                  }
              });
}

QString LiveActivities::preferredDisplay() const
{
    // niche follows the main display; here the built-in panel when there is one.
    QString first;
    for (const QString &name : m_displayOrder) {
        auto it = m_displays.constFind(name);
        if (it == m_displays.constEnd() || !it->loaded) {
            continue;
        }
        if (it->internal) {
            return name;
        }
        if (first.isEmpty()) {
            first = name;
        }
    }
    return first;
}

void LiveActivities::onBrightnessChanged(const QString &display, int brightness, const QString &sourceClient, const QString &sourceContext)
{
    Q_UNUSED(sourceClient)
    if (!m_displayOrder.contains(display)) {
        m_displayOrder.append(display);
    }
    Display &info = m_displays[display];
    info.brightness = brightness;
    // powerdevil tags its own brightness-key handling with this context; niche
    // likewise only reacts to brightness keys, not sliders or idle dimming.
    const bool byKey = sourceContext == QLatin1String("brightness_key");
    if (!info.loaded) {
        info.showWhenLoaded = info.showWhenLoaded || byKey;
        loadDisplay(display);
        return;
    }
    if (preferredDisplay() != display || info.max <= 0) {
        return;
    }
    if (byKey) {
        brightnessChanged(display);
    } else {
        m_lastBrightness = double(brightness) / info.max;
    }
}

void LiveActivities::brightnessChanged(const QString &display)
{
    const Display &info = m_displays[display];
    const double level = qBound(0.0, double(info.brightness) / info.max, 1.0);
    if (!m_lastBrightness || std::abs(*m_lastBrightness - level) > 0.001) {
        Activity activity;
        activity.kind = QStringLiteral("brightness");
        activity.level = level;
        activity.iconName = QStringLiteral("brightness-high-symbolic");
        show(activity, 1.4);
    }
    m_lastBrightness = level;
}

void LiveActivities::onBrightnessRangeChanged(const QString &display, int maxBrightness, int brightness)
{
    auto it = m_displays.find(display);
    if (it == m_displays.end()) {
        return;
    }
    it->max = maxBrightness;
    it->brightness = brightness;
}

void LiveActivities::onDisplayAdded(const QString &display)
{
    if (!m_displayOrder.contains(display)) {
        m_displayOrder.append(display);
    }
    loadDisplay(display);
}

void LiveActivities::onDisplayRemoved(const QString &display)
{
    const QString preferred = preferredDisplay();
    m_displayOrder.removeAll(display);
    m_displays.remove(display);
    if (preferred == display) {
        m_lastBrightness.reset();
    }
}

// MARK: - Battery

void LiveActivities::startBattery()
{
    QDBusConnection bus = QDBusConnection::systemBus();
    bus.connect(UPowerService, UPowerDevicePath, PropertiesInterface, PropertiesChanged, this, SLOT(onUPowerDeviceProperties(QString, QVariantMap, QStringList)));
    bus.connect(UPowerService, UPowerPath, PropertiesInterface, PropertiesChanged, this, SLOT(onUPowerProperties(QString, QVariantMap, QStringList)));
    m_batteryWatching = true;
    m_haveDevice = false;
    m_haveRoot = false;

    const quint64 generation = m_generation;
    callAsync(bus, propertyGetAll(UPowerService, UPowerDevicePath, UPowerDeviceInterface), this, [this, generation](const QList<QVariant> &arguments) {
        if (generation != m_generation || arguments.isEmpty()) {
            return;
        }
        onUPowerDeviceProperties(UPowerDeviceInterface, qdbus_cast<QVariantMap>(arguments.constFirst()), {});
        m_haveDevice = true;
        readBattery();
    });
    callAsync(bus, propertyGet(UPowerService, UPowerPath, UPowerService, QStringLiteral("OnBattery")), this, [this, generation](const QList<QVariant> &arguments) {
        if (generation != m_generation || arguments.isEmpty()) {
            return;
        }
        m_onBattery = unwrap(arguments.constFirst()).toBool();
        m_haveRoot = true;
        readBattery();
    });
}

void LiveActivities::stopBattery()
{
    if (!m_batteryWatching) {
        return;
    }
    QDBusConnection bus = QDBusConnection::systemBus();
    bus.disconnect(UPowerService, UPowerDevicePath, PropertiesInterface, PropertiesChanged, this, SLOT(onUPowerDeviceProperties(QString, QVariantMap, QStringList)));
    bus.disconnect(UPowerService, UPowerPath, PropertiesInterface, PropertiesChanged, this, SLOT(onUPowerProperties(QString, QVariantMap, QStringList)));
    m_batteryWatching = false;
    m_batteryTimer.stop();
    m_haveDevice = false;
    m_haveRoot = false;
}

void LiveActivities::onUPowerDeviceProperties(const QString &interface, const QVariantMap &changed, const QStringList &invalidated)
{
    Q_UNUSED(invalidated)
    if (interface != UPowerDeviceInterface) {
        return;
    }
    if (auto it = changed.constFind(QStringLiteral("Percentage")); it != changed.constEnd()) {
        m_percentage = unwrap(it.value()).toDouble();
    }
    if (auto it = changed.constFind(QStringLiteral("State")); it != changed.constEnd()) {
        m_batteryState = unwrap(it.value()).toUInt();
    }
    if (auto it = changed.constFind(QStringLiteral("Type")); it != changed.constEnd()) {
        m_batteryType = unwrap(it.value()).toUInt();
    }
    if (auto it = changed.constFind(QStringLiteral("IsPresent")); it != changed.constEnd()) {
        m_batteryPresent = unwrap(it.value()).toBool();
    }
    m_batteryTimer.start();
}

void LiveActivities::onUPowerProperties(const QString &interface, const QVariantMap &changed, const QStringList &invalidated)
{
    Q_UNUSED(invalidated)
    if (interface != UPowerService) {
        return;
    }
    if (auto it = changed.constFind(QStringLiteral("OnBattery")); it != changed.constEnd()) {
        m_onBattery = unwrap(it.value()).toBool();
        m_batteryTimer.start();
    }
}

void LiveActivities::readBattery()
{
    if (!m_haveDevice || !m_haveRoot) {
        return;
    }
    if (!m_batteryPresent || m_batteryType != UPowerTypeBattery) {
        m_lastBattery.reset();
        return;
    }
    const int level = qBound(0, int(std::floor(m_percentage)), 100);
    const bool onAC = !m_onBattery;
    const bool full = onAC && (level >= 100 || m_batteryState == UPowerStateFullyCharged);
    const Battery now{level, onAC, full};
    if (m_lastBattery) {
        const Battery last = *m_lastBattery;
        const double fraction = level / 100.0;
        Activity activity;
        activity.level = fraction;
        activity.text = percentText(fraction);
        if (full && !last.full && watching(QStringLiteral("fullyCharged"))) {
            activity.kind = QStringLiteral("fullyCharged");
            activity.iconName = QStringLiteral("battery-full-symbolic");
            show(activity, 2.5);
        } else if (onAC && !last.onAC && watching(QStringLiteral("charging"))) {
            activity.kind = QStringLiteral("charging");
            activity.iconName = QStringLiteral("battery-100-charging-symbolic");
            show(activity, 2);
        } else if (!onAC && level <= LowBatteryThreshold && (last.onAC || last.level > LowBatteryThreshold || (level <= 10 && last.level > 10))
                   && watching(QStringLiteral("lowBattery"))) {
            activity.kind = QStringLiteral("lowBattery");
            activity.iconName = level <= 10 ? QStringLiteral("battery-010-symbolic") : QStringLiteral("battery-020-symbolic");
            show(activity, 3);
        }
    }
    m_lastBattery = now;
}

// MARK: - Headphones

void LiveActivities::startHeadphones()
{
    if (m_headphones) {
        return;
    }
    m_headphones = new HeadphonesWatcher(this);
    connect(m_headphones, &HeadphonesWatcher::connected, this, [this](const QString &name, const QString &icon, double level) {
        if (!watching(QStringLiteral("headphones"))) {
            return;
        }
        Activity activity;
        activity.kind = QStringLiteral("headphones");
        activity.level = level > 0 ? level : 0;
        activity.isOn = true;
        activity.detail = name;
        activity.iconName = icon;
        activity.text = activity.level > 0 ? percentText(activity.level) : QString();
        show(activity, 2.5);
    });
    connect(m_headphones, &HeadphonesWatcher::disconnected, this, [this](const QString &name, const QString &icon) {
        if (!watching(QStringLiteral("headphones"))) {
            return;
        }
        Activity activity;
        activity.kind = QStringLiteral("headphones");
        activity.isOn = false;
        activity.text = QStringLiteral("Off");
        activity.detail = name;
        activity.iconName = icon;
        show(activity, 2);
    });
    connect(m_headphones, &HeadphonesWatcher::lowBattery, this, [this](const QString &name, const QString &icon, double level) {
        if (!watching(QStringLiteral("headphonesBattery"))) {
            return;
        }
        Activity activity;
        activity.kind = QStringLiteral("headphonesBattery");
        activity.level = level;
        activity.text = percentText(level);
        activity.detail = name;
        activity.iconName = icon;
        show(activity, 3);
    });
    m_headphones->start();
}

void LiveActivities::stopHeadphones()
{
    if (!m_headphones) {
        return;
    }
    m_headphones->stop();
    delete m_headphones;
    m_headphones = nullptr;
}
