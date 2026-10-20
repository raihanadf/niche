#pragma once

#include <QByteArray>
#include <QList>
#include <QObject>
#include <QSet>
#include <QTimer>

#include <array>
#include <memory>

#include <pulse/pulseaudio.h>

struct pa_glib_mainloop;
class SpectrumAnalyzer;

// Live bar levels for the music visualizer (niche's AudioSpectrum). niche taps
// the playing process; PulseAudio offers the default sink's monitor instead,
// which carries everything the speakers play. The capture stream (and its
// context) only exists while enabled && running.
class AudioSpectrum : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
    Q_PROPERTY(QList<qreal> levels READ levels NOTIFY levelsChanged)
    Q_PROPERTY(int bands READ bands CONSTANT)

public:
    static constexpr int Bands = 4;

    explicit AudioSpectrum(QObject *parent = nullptr);
    ~AudioSpectrum() override;

    bool enabled() const { return m_enabled; }
    void setEnabled(bool enabled);
    bool running() const { return m_running; }
    void setRunning(bool running);
    QList<qreal> levels() const { return m_levels; }
    int bands() const { return Bands; }

    // Bar views register while they are visible and music plays; capture runs
    // while any viewer is active or `running` is set (and `enabled`). Viewers
    // are dropped automatically when destroyed.
    Q_INVOKABLE void watch(QObject *viewer, bool active);

Q_SIGNALS:
    void enabledChanged();
    void runningChanged();
    void levelsChanged();

private:
    static void stateCallback(pa_context *context, void *userdata);
    static void subscribeCallback(pa_context *context, pa_subscription_event_type_t type, uint32_t index, void *userdata);
    static void serverInfoCallback(pa_context *context, const pa_server_info *info, void *userdata);
    static void sinkInfoCallback(pa_context *context, const pa_sink_info *info, int eol, void *userdata);
    static void streamStateCallback(pa_stream *stream, void *userdata);
    static void readCallback(pa_stream *stream, size_t bytes, void *userdata);

    bool wanted() const;
    void update();
    void start();
    void stop();
    void dropStream();
    void publish(const std::array<float, Bands> &levels);
    void capture(const QByteArray &source);
    void resetLevels();

    bool m_enabled = false;
    bool m_running = false;
    QSet<QObject *> m_viewers;
    QList<qreal> m_levels;

    pa_glib_mainloop *m_loop = nullptr;
    pa_context *m_context = nullptr;
    pa_stream *m_stream = nullptr;
    QByteArray m_sinkName;
    QByteArray m_source;
    std::unique_ptr<SpectrumAnalyzer> m_analyzer;
    QTimer m_retry;
};
