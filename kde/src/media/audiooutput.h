#pragma once

#include <QObject>
#include <QString>
#include <QTimer>

#include <pulse/pulseaudio.h>

struct pa_glib_mainloop;

// The default PulseAudio (pipewire-pulse) sink: its volume, mute state and the
// icon for what kind of device it is. Mirrors niche's OutputDevice, which
// follows the default output device and listens to its volume and mute.
class AudioOutput : public QObject
{
    Q_OBJECT
    Q_PROPERTY(qreal volume READ volume NOTIFY volumeChanged)
    Q_PROPERTY(bool muted READ muted NOTIFY mutedChanged)
    Q_PROPERTY(bool canSetVolume READ canSetVolume NOTIFY canSetVolumeChanged)
    Q_PROPERTY(QString iconName READ iconName NOTIFY iconNameChanged)
    Q_PROPERTY(QString deviceName READ deviceName NOTIFY deviceNameChanged)

public:
    explicit AudioOutput(QObject *parent = nullptr);
    ~AudioOutput() override;

    qreal volume() const { return m_volume; }
    bool muted() const { return m_muted; }
    bool canSetVolume() const { return m_canSetVolume; }
    QString iconName() const { return m_iconName; }
    QString deviceName() const { return m_deviceName; }

    // Level 0..1 of the loudest channel (channel balance is kept). Raising the
    // volume of a muted sink unmutes it, like niche.
    Q_INVOKABLE void setVolume(qreal level);
    Q_INVOKABLE void toggleMute();

Q_SIGNALS:
    void volumeChanged();
    void mutedChanged();
    void canSetVolumeChanged();
    void iconNameChanged();
    void deviceNameChanged();
    // The server reported a new volume or mute state for the sink that was
    // already the default one. Not emitted for the first reading of a sink
    // (startup, default device switch).
    void adjusted();

private:
    static void stateCallback(pa_context *context, void *userdata);
    static void subscribeCallback(pa_context *context, pa_subscription_event_type_t type, uint32_t index, void *userdata);
    static void serverInfoCallback(pa_context *context, const pa_server_info *info, void *userdata);
    static void sinkInfoCallback(pa_context *context, const pa_sink_info *info, int eol, void *userdata);
    static void changeCallback(pa_context *context, int success, void *userdata);

    void connectContext();
    void dropContext();
    void requestServerInfo();
    void requestSinkByName();
    void requestSinkByIndex();
    void readSink(const pa_sink_info *info);
    void trackChange(pa_operation *operation);

    void setVolumeValue(qreal volume);
    void setMutedValue(bool muted);
    void setCanSetVolume(bool can);
    void setIconName(const QString &name);
    void setDeviceName(const QString &name);

    pa_glib_mainloop *m_loop = nullptr;
    pa_context *m_context = nullptr;
    QTimer m_retry;

    QString m_sinkName;
    uint32_t m_sinkIndex = PA_INVALID_INDEX;
    pa_cvolume m_channels{};
    // Last values the server reported for the current sink; adjusted() fires
    // when a later reading differs.
    bool m_hasReading = false;
    pa_volume_t m_lastRaw = 0;
    bool m_lastMute = false;
    // Volume/mute requests still in flight; server readings don't overwrite
    // the optimistic slider value until they settle.
    int m_pendingChanges = 0;

    qreal m_volume = 0;
    bool m_muted = false;
    bool m_canSetVolume = false;
    QString m_iconName = QStringLiteral("audio-speakers-symbolic");
    QString m_deviceName;
};
