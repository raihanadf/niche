#include <pulse/glib-mainloop.h>

#include "media/audiooutput.h"

#include <QFile>

#include <algorithm>
#include <cmath>

namespace
{
constexpr int reconnectDelay = 2000;

const QString speakersIcon = QStringLiteral("audio-speakers-symbolic");
const QString headphonesIcon = QStringLiteral("audio-headphones-symbolic");
const QString headsetIcon = QStringLiteral("audio-headset-symbolic");
const QString laptopIcon = QStringLiteral("computer-laptop-symbolic");
const QString displayIcon = QStringLiteral("video-television");

bool isLaptop()
{
    static const bool laptop = [] {
        QFile file(QStringLiteral("/sys/class/dmi/id/chassis_type"));
        if (!file.open(QIODevice::ReadOnly)) {
            return false;
        }
        // SMBIOS chassis types: portable, laptop, notebook, sub notebook,
        // convertible, detachable.
        const int type = file.readAll().trimmed().toInt();
        return type == 8 || type == 9 || type == 10 || type == 14 || type == 31 || type == 32;
    }();
    return laptop;
}

QString property(const pa_sink_info *info, const char *key)
{
    const char *value = info->proplist ? pa_proplist_gets(info->proplist, key) : nullptr;
    return value ? QString::fromUtf8(value).toLower() : QString();
}

// niche's OutputDevice.deviceSymbol, keyed on what PulseAudio knows: the bus,
// the form factor and the active port's type.
QString deviceIcon(const pa_sink_info *info)
{
    const QString bus = property(info, PA_PROP_DEVICE_BUS);
    const QString form = property(info, PA_PROP_DEVICE_FORM_FACTOR);
    const QString label = QString::fromUtf8(info->description ? info->description : "").toLower();
    const QString name = QString::fromUtf8(info->name ? info->name : "").toLower();
    uint32_t portType = PA_DEVICE_PORT_TYPE_UNKNOWN;
    QString port;
    if (info->active_port) {
        portType = info->active_port->type;
        port = QString::fromUtf8(info->active_port->name ? info->active_port->name : "").toLower();
    }

    const bool bluetooth = bus == QLatin1String("bluetooth") || portType == PA_DEVICE_PORT_TYPE_BLUETOOTH || name.startsWith(QLatin1String("bluez"));
    if (bluetooth) {
        if (form == QLatin1String("speaker") || form == QLatin1String("hifi") || form == QLatin1String("portable") || label.contains(QLatin1String("speaker"))) {
            return speakersIcon;
        }
        if (form == QLatin1String("headset") || form == QLatin1String("hands-free") || portType == PA_DEVICE_PORT_TYPE_HEADSET
            || portType == PA_DEVICE_PORT_TYPE_HANDSFREE) {
            return headsetIcon;
        }
        return headphonesIcon;
    }
    if (portType == PA_DEVICE_PORT_TYPE_HEADPHONES || form == QLatin1String("headphone") || port.contains(QLatin1String("headphone"))) {
        return headphonesIcon;
    }
    if (portType == PA_DEVICE_PORT_TYPE_HEADSET || form == QLatin1String("headset") || port.contains(QLatin1String("headset"))) {
        return headsetIcon;
    }
    if (portType == PA_DEVICE_PORT_TYPE_HDMI || portType == PA_DEVICE_PORT_TYPE_TV || form == QLatin1String("tv") || port.contains(QLatin1String("hdmi"))
        || port.contains(QLatin1String("displayport"))) {
        return displayIcon;
    }
    const bool builtIn = form == QLatin1String("internal") || (bus == QLatin1String("pci") && portType == PA_DEVICE_PORT_TYPE_SPEAKER);
    if (builtIn && isLaptop()) {
        return laptopIcon;
    }
    return speakersIcon;
}

void release(pa_operation *operation)
{
    if (operation) {
        pa_operation_unref(operation);
    }
}

qreal volumeLevel(pa_volume_t raw)
{
    return std::clamp(double(raw) / double(PA_VOLUME_NORM), 0.0, 1.0);
}
}

AudioOutput::AudioOutput(QObject *parent)
    : QObject(parent)
    , m_loop(pa_glib_mainloop_new(nullptr))
{
    m_retry.setSingleShot(true);
    m_retry.setInterval(reconnectDelay);
    connect(&m_retry, &QTimer::timeout, this, &AudioOutput::connectContext);
    connectContext();
}

AudioOutput::~AudioOutput()
{
    dropContext();
    pa_glib_mainloop_free(m_loop);
}

void AudioOutput::connectContext()
{
    dropContext();
    m_context = pa_context_new(pa_glib_mainloop_get_api(m_loop), "niche-kde");
    if (!m_context) {
        m_retry.start();
        return;
    }
    pa_context_set_state_callback(m_context, &AudioOutput::stateCallback, this);
    if (pa_context_connect(m_context, nullptr, PA_CONTEXT_NOFAIL, nullptr) < 0) {
        dropContext();
        m_retry.start();
    }
}

void AudioOutput::dropContext()
{
    if (!m_context) {
        return;
    }
    pa_context_set_state_callback(m_context, nullptr, nullptr);
    pa_context_set_subscribe_callback(m_context, nullptr, nullptr);
    pa_context_disconnect(m_context);
    pa_context_unref(m_context);
    m_context = nullptr;
    m_sinkName.clear();
    m_sinkIndex = PA_INVALID_INDEX;
    m_hasReading = false;
    m_pendingChanges = 0;
    setCanSetVolume(false);
}

void AudioOutput::stateCallback(pa_context *context, void *userdata)
{
    auto *self = static_cast<AudioOutput *>(userdata);
    if (context != self->m_context) {
        return;
    }
    switch (pa_context_get_state(context)) {
    case PA_CONTEXT_READY:
        pa_context_set_subscribe_callback(context, &AudioOutput::subscribeCallback, self);
        release(pa_context_subscribe(context, pa_subscription_mask_t(PA_SUBSCRIPTION_MASK_SINK | PA_SUBSCRIPTION_MASK_SERVER), nullptr, nullptr));
        self->requestServerInfo();
        break;
    case PA_CONTEXT_FAILED:
    case PA_CONTEXT_TERMINATED:
        // Never free the context from inside its own callback.
        QMetaObject::invokeMethod(
            self,
            [self, context] {
                if (self->m_context == context) {
                    self->dropContext();
                    self->m_retry.start();
                }
            },
            Qt::QueuedConnection);
        break;
    default:
        break;
    }
}

void AudioOutput::subscribeCallback(pa_context *context, pa_subscription_event_type_t type, uint32_t index, void *userdata)
{
    auto *self = static_cast<AudioOutput *>(userdata);
    if (context != self->m_context) {
        return;
    }
    const int facility = type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
    const int kind = type & PA_SUBSCRIPTION_EVENT_TYPE_MASK;
    if (facility == PA_SUBSCRIPTION_EVENT_SERVER) {
        self->requestServerInfo();
    } else if (facility == PA_SUBSCRIPTION_EVENT_SINK) {
        if (index == self->m_sinkIndex) {
            if (kind == PA_SUBSCRIPTION_EVENT_REMOVE) {
                self->m_sinkIndex = PA_INVALID_INDEX;
                self->requestServerInfo();
            } else {
                self->requestSinkByIndex();
            }
        } else if (kind == PA_SUBSCRIPTION_EVENT_NEW && self->m_sinkIndex == PA_INVALID_INDEX) {
            self->requestSinkByName();
        }
    }
}

void AudioOutput::requestServerInfo()
{
    if (m_context) {
        release(pa_context_get_server_info(m_context, &AudioOutput::serverInfoCallback, this));
    }
}

void AudioOutput::requestSinkByName()
{
    if (!m_context || m_sinkName.isEmpty()) {
        return;
    }
    const QByteArray name = m_sinkName.toUtf8();
    release(pa_context_get_sink_info_by_name(m_context, name.constData(), &AudioOutput::sinkInfoCallback, this));
}

void AudioOutput::requestSinkByIndex()
{
    if (m_context && m_sinkIndex != PA_INVALID_INDEX) {
        release(pa_context_get_sink_info_by_index(m_context, m_sinkIndex, &AudioOutput::sinkInfoCallback, this));
    }
}

void AudioOutput::serverInfoCallback(pa_context *context, const pa_server_info *info, void *userdata)
{
    auto *self = static_cast<AudioOutput *>(userdata);
    if (context != self->m_context || !info) {
        return;
    }
    const QString name = QString::fromUtf8(info->default_sink_name ? info->default_sink_name : "");
    if (name != self->m_sinkName) {
        // A different default sink: its first reading is not an adjustment.
        self->m_sinkName = name;
        self->m_sinkIndex = PA_INVALID_INDEX;
        self->m_hasReading = false;
        self->m_pendingChanges = 0;
    }
    if (name.isEmpty()) {
        self->setCanSetVolume(false);
        return;
    }
    self->requestSinkByName();
}

void AudioOutput::sinkInfoCallback(pa_context *context, const pa_sink_info *info, int eol, void *userdata)
{
    auto *self = static_cast<AudioOutput *>(userdata);
    if (context != self->m_context || eol != 0 || !info || !info->name) {
        return;
    }
    if (QString::fromUtf8(info->name) != self->m_sinkName) {
        return;
    }
    self->readSink(info);
}

void AudioOutput::readSink(const pa_sink_info *info)
{
    m_sinkIndex = info->index;
    m_channels = info->volume;
    const pa_volume_t raw = pa_cvolume_max(&info->volume);
    const bool mute = info->mute != 0;
    const bool changed = m_hasReading && (raw != m_lastRaw || mute != m_lastMute);
    m_lastRaw = raw;
    m_lastMute = mute;
    m_hasReading = true;

    if (m_pendingChanges == 0) {
        setVolumeValue(volumeLevel(raw));
        setMutedValue(mute);
    }
    setDeviceName(QString::fromUtf8(info->description ? info->description : info->name));
    setIconName(deviceIcon(info));
    setCanSetVolume(pa_cvolume_valid(&m_channels) != 0);
    if (changed) {
        Q_EMIT adjusted();
    }
}

void AudioOutput::trackChange(pa_operation *operation)
{
    if (operation) {
        ++m_pendingChanges;
        pa_operation_unref(operation);
    }
}

void AudioOutput::changeCallback(pa_context *context, int, void *userdata)
{
    auto *self = static_cast<AudioOutput *>(userdata);
    if (context != self->m_context) {
        return;
    }
    if (self->m_pendingChanges > 0 && --self->m_pendingChanges == 0) {
        // Settle the optimistic value on what the server actually applied.
        self->requestSinkByIndex();
    }
}

void AudioOutput::setVolume(qreal level)
{
    if (!m_context || !m_canSetVolume || m_sinkIndex == PA_INVALID_INDEX) {
        return;
    }
    level = std::clamp(level, 0.0, 1.0);
    pa_cvolume target = m_channels;
    pa_cvolume_scale(&target, pa_volume_t(std::lround(level * PA_VOLUME_NORM)));
    trackChange(pa_context_set_sink_volume_by_index(m_context, m_sinkIndex, &target, &AudioOutput::changeCallback, this));
    m_channels = target;
    if (m_muted && level > 0) {
        toggleMute();
    }
    setVolumeValue(level);
}

void AudioOutput::toggleMute()
{
    if (!m_context || m_sinkIndex == PA_INVALID_INDEX) {
        return;
    }
    const bool mute = !m_muted;
    trackChange(pa_context_set_sink_mute_by_index(m_context, m_sinkIndex, mute ? 1 : 0, &AudioOutput::changeCallback, this));
    setMutedValue(mute);
}

void AudioOutput::setVolumeValue(qreal volume)
{
    if (qFuzzyCompare(m_volume + 1.0, volume + 1.0)) {
        return;
    }
    m_volume = volume;
    Q_EMIT volumeChanged();
}

void AudioOutput::setMutedValue(bool muted)
{
    if (m_muted == muted) {
        return;
    }
    m_muted = muted;
    Q_EMIT mutedChanged();
}

void AudioOutput::setCanSetVolume(bool can)
{
    if (m_canSetVolume == can) {
        return;
    }
    m_canSetVolume = can;
    Q_EMIT canSetVolumeChanged();
}

void AudioOutput::setIconName(const QString &name)
{
    if (m_iconName == name) {
        return;
    }
    m_iconName = name;
    Q_EMIT iconNameChanged();
}

void AudioOutput::setDeviceName(const QString &name)
{
    if (m_deviceName == name) {
        return;
    }
    m_deviceName = name;
    Q_EMIT deviceNameChanged();
}
