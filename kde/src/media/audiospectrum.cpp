#include <pulse/glib-mainloop.h>

#include "media/audiospectrum.h"

#include <QElapsedTimer>

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <numbers>
#include <vector>

namespace
{
// 24 kHz mono is enough for niche's top band edge (12 kHz) and keeps the
// capture cheap; PulseAudio downmixes and resamples for us.
constexpr uint32_t sampleRate = 24000;
constexpr int reconnectDelay = 2000;

void release(pa_operation *operation)
{
    if (operation) {
        pa_operation_unref(operation);
    }
}
}

// niche's SpectrumAnalyzer: 1024-point Hann-windowed FFT with 50 % overlap,
// four log-spaced bands, adaptive floor/ceiling plus onset emphasis, and
// asymmetric smoothing. The FFT is a plain iterative radix-2 transform.
class SpectrumAnalyzer
{
public:
    static constexpr int N = 1024;

    explicit SpectrumAnalyzer(float rate)
    {
        constexpr double tau = 2.0 * std::numbers::pi;
        for (int i = 0; i < N; ++i) {
            m_window[i] = float(0.5 * (1.0 - std::cos(tau * i / N)));
        }
        for (int k = 0; k < N / 2; ++k) {
            m_twiddle[k] = std::polar(1.0f, float(-tau * k / N));
        }
        int bits = 0;
        while ((1 << bits) < N) {
            ++bits;
        }
        for (int i = 0; i < N; ++i) {
            int reversed = 0;
            for (int b = 0; b < bits; ++b) {
                reversed |= ((i >> b) & 1) << (bits - 1 - b);
            }
            m_reverse[i] = reversed;
        }
        const float binHz = rate / N;
        const std::array<float, AudioSpectrum::Bands + 1> hz{30.0f, 150.0f, 600.0f, 2500.0f, 12000.0f};
        for (size_t i = 0; i < hz.size(); ++i) {
            m_edges[i] = std::min(N / 2 - 1, std::max(1, int(std::lround(hz[i] / binHz))));
        }
        m_smoothed.fill(0.0f);
        m_ceiling.fill(-30.0f);
        m_floor.fill(-60.0f);
        m_average.fill(-45.0f);
        m_pending.reserve(2 * N);
        m_clock.start();
    }

    // Feeds mono samples; returns true when `levels` holds a fresh frame to
    // publish (at most 60 per second, like niche).
    bool process(const float *samples, size_t count, std::array<float, AudioSpectrum::Bands> &levels)
    {
        m_pending.insert(m_pending.end(), samples, samples + count);
        if (m_pending.size() < size_t(N)) {
            return false;
        }
        const float *frame = m_pending.data() + (m_pending.size() - N);
        for (int i = 0; i < N; ++i) {
            m_buffer[m_reverse[i]] = std::complex<float>(frame[i] * m_window[i], 0.0f);
        }
        m_pending.erase(m_pending.begin(), m_pending.begin() + std::ptrdiff_t(m_pending.size() - N / 2));

        for (int size = 2; size <= N; size <<= 1) {
            const int half = size / 2;
            const int stride = N / size;
            for (int start = 0; start < N; start += size) {
                for (int k = 0; k < half; ++k) {
                    const std::complex<float> t = m_twiddle[k * stride] * m_buffer[start + k + half];
                    const std::complex<float> u = m_buffer[start + k];
                    m_buffer[start + k] = u + t;
                    m_buffer[start + k + half] = u - t;
                }
            }
        }

        constexpr float scale = float(N) * float(N);
        for (int b = 0; b < AudioSpectrum::Bands; ++b) {
            const int from = m_edges[b];
            const int to = std::max(from + 1, m_edges[b + 1]);
            float sum = 0.0f;
            for (int k = from; k < to; ++k) {
                // vDSP's real FFT reports twice the DFT magnitude; keep its scale
                // so niche's absolute -30/-60 dB starting points still fit.
                const float magnitude = 2.0f * std::abs(m_buffer[k]);
                sum += magnitude * magnitude;
            }
            const float power = sum / float(to - from) / scale;
            const float db = 10.0f * std::log10(std::max(power, 1e-12f));

            m_ceiling[b] = db > m_ceiling[b] ? db : m_ceiling[b] - 0.05f;
            m_floor[b] = db < m_floor[b] ? db : m_floor[b] + 0.02f;
            const float range = std::max(m_ceiling[b] - m_floor[b], 18.0f);
            const float position = std::clamp((db - (m_ceiling[b] - range)) / range, 0.0f, 1.0f);

            const float onset = std::min(1.0f, std::max(0.0f, db - m_average[b]) / 8.0f);
            m_average[b] += (db - m_average[b]) * 0.04f;
            const float level = std::min(1.0f, position * 0.35f + onset * 0.8f);
            m_smoothed[b] += (level - m_smoothed[b]) * (level > m_smoothed[b] ? 0.75f : 0.22f);
        }

        if (m_published && m_clock.elapsed() < 1000 / 60) {
            return false;
        }
        m_published = true;
        m_clock.restart();
        levels = m_smoothed;
        return true;
    }

private:
    std::array<float, N> m_window{};
    std::array<std::complex<float>, N / 2> m_twiddle{};
    std::array<int, N> m_reverse{};
    std::array<std::complex<float>, N> m_buffer{};
    std::array<int, AudioSpectrum::Bands + 1> m_edges{};
    std::array<float, AudioSpectrum::Bands> m_smoothed{};
    std::array<float, AudioSpectrum::Bands> m_ceiling{};
    std::array<float, AudioSpectrum::Bands> m_floor{};
    std::array<float, AudioSpectrum::Bands> m_average{};
    std::vector<float> m_pending;
    QElapsedTimer m_clock;
    bool m_published = false;
};

AudioSpectrum::AudioSpectrum(QObject *parent)
    : QObject(parent)
{
    m_levels = QList<qreal>(Bands, 0.0);
    m_retry.setSingleShot(true);
    m_retry.setInterval(reconnectDelay);
    connect(&m_retry, &QTimer::timeout, this, &AudioSpectrum::update);
}

AudioSpectrum::~AudioSpectrum()
{
    stop();
    if (m_loop) {
        pa_glib_mainloop_free(m_loop);
    }
}

void AudioSpectrum::setEnabled(bool enabled)
{
    if (m_enabled == enabled) {
        return;
    }
    m_enabled = enabled;
    Q_EMIT enabledChanged();
    update();
}

void AudioSpectrum::setRunning(bool running)
{
    if (m_running == running) {
        return;
    }
    m_running = running;
    Q_EMIT runningChanged();
    update();
}

void AudioSpectrum::watch(QObject *viewer, bool active)
{
    if (!viewer) {
        return;
    }
    if (active) {
        if (!m_viewers.contains(viewer)) {
            m_viewers.insert(viewer);
            connect(viewer, &QObject::destroyed, this, [this, viewer] {
                m_viewers.remove(viewer);
                update();
            });
        }
    } else if (m_viewers.remove(viewer)) {
        disconnect(viewer, &QObject::destroyed, this, nullptr);
    }
    update();
}

bool AudioSpectrum::wanted() const
{
    return m_enabled && (m_running || !m_viewers.isEmpty());
}

void AudioSpectrum::update()
{
    if (wanted()) {
        if (!m_context) {
            start();
        }
    } else {
        m_retry.stop();
        stop();
    }
}

void AudioSpectrum::start()
{
    resetLevels();
    if (!m_loop) {
        m_loop = pa_glib_mainloop_new(nullptr);
    }
    m_context = pa_context_new(pa_glib_mainloop_get_api(m_loop), "niche-kde visualizer");
    if (!m_context) {
        m_retry.start();
        return;
    }
    pa_context_set_state_callback(m_context, &AudioSpectrum::stateCallback, this);
    if (pa_context_connect(m_context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0) {
        stop();
        m_retry.start();
    }
}

void AudioSpectrum::stop()
{
    dropStream();
    if (m_context) {
        pa_context_set_state_callback(m_context, nullptr, nullptr);
        pa_context_set_subscribe_callback(m_context, nullptr, nullptr);
        pa_context_disconnect(m_context);
        pa_context_unref(m_context);
        m_context = nullptr;
    }
    m_sinkName.clear();
    resetLevels();
}

void AudioSpectrum::dropStream()
{
    if (m_stream) {
        pa_stream_set_state_callback(m_stream, nullptr, nullptr);
        pa_stream_set_read_callback(m_stream, nullptr, nullptr);
        pa_stream_disconnect(m_stream);
        pa_stream_unref(m_stream);
        m_stream = nullptr;
    }
    m_source.clear();
    m_analyzer.reset();
}

void AudioSpectrum::resetLevels()
{
    const QList<qreal> zero(Bands, 0.0);
    if (m_levels != zero) {
        m_levels = zero;
        Q_EMIT levelsChanged();
    }
}

void AudioSpectrum::stateCallback(pa_context *context, void *userdata)
{
    auto *self = static_cast<AudioSpectrum *>(userdata);
    if (context != self->m_context) {
        return;
    }
    switch (pa_context_get_state(context)) {
    case PA_CONTEXT_READY:
        pa_context_set_subscribe_callback(context, &AudioSpectrum::subscribeCallback, self);
        release(pa_context_subscribe(context, PA_SUBSCRIPTION_MASK_SERVER, nullptr, nullptr));
        release(pa_context_get_server_info(context, &AudioSpectrum::serverInfoCallback, self));
        break;
    case PA_CONTEXT_FAILED:
    case PA_CONTEXT_TERMINATED:
        QMetaObject::invokeMethod(
            self,
            [self, context] {
                if (self->m_context == context) {
                    self->stop();
                    self->m_retry.start();
                }
            },
            Qt::QueuedConnection);
        break;
    default:
        break;
    }
}

void AudioSpectrum::subscribeCallback(pa_context *context, pa_subscription_event_type_t type, uint32_t, void *userdata)
{
    auto *self = static_cast<AudioSpectrum *>(userdata);
    if (context != self->m_context) {
        return;
    }
    if ((type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK) == PA_SUBSCRIPTION_EVENT_SERVER) {
        release(pa_context_get_server_info(context, &AudioSpectrum::serverInfoCallback, self));
    }
}

void AudioSpectrum::serverInfoCallback(pa_context *context, const pa_server_info *info, void *userdata)
{
    auto *self = static_cast<AudioSpectrum *>(userdata);
    if (context != self->m_context || !info || !info->default_sink_name) {
        return;
    }
    const QByteArray sink(info->default_sink_name);
    if (sink == self->m_sinkName && self->m_stream) {
        return;
    }
    self->m_sinkName = sink;
    release(pa_context_get_sink_info_by_name(context, sink.constData(), &AudioSpectrum::sinkInfoCallback, self));
}

void AudioSpectrum::sinkInfoCallback(pa_context *context, const pa_sink_info *info, int eol, void *userdata)
{
    auto *self = static_cast<AudioSpectrum *>(userdata);
    if (context != self->m_context || eol != 0 || !info || !info->name || self->m_sinkName != info->name) {
        return;
    }
    if (info->monitor_source_name) {
        self->capture(QByteArray(info->monitor_source_name));
    }
}

void AudioSpectrum::capture(const QByteArray &source)
{
    if (m_stream && source == m_source) {
        return;
    }
    dropStream();

    const pa_sample_spec spec{PA_SAMPLE_FLOAT32NE, sampleRate, 1};
    pa_proplist *props = pa_proplist_new();
    pa_proplist_sets(props, PA_PROP_APPLICATION_NAME, "niche");
    pa_proplist_sets(props, PA_PROP_APPLICATION_ID, "org.niche.Island");
    pa_proplist_sets(props, PA_PROP_MEDIA_NAME, "Live visualizer");
    m_stream = pa_stream_new_with_proplist(m_context, "Live visualizer", &spec, nullptr, props);
    pa_proplist_free(props);
    if (!m_stream) {
        return;
    }
    m_source = source;
    m_analyzer = std::make_unique<SpectrumAnalyzer>(float(sampleRate));
    pa_stream_set_state_callback(m_stream, &AudioSpectrum::streamStateCallback, this);
    pa_stream_set_read_callback(m_stream, &AudioSpectrum::readCallback, this);

    // Half an analysis frame per fragment: one FFT per callback, ~47 per second.
    pa_buffer_attr attr;
    attr.maxlength = uint32_t(-1);
    attr.tlength = uint32_t(-1);
    attr.prebuf = uint32_t(-1);
    attr.minreq = uint32_t(-1);
    attr.fragsize = uint32_t(SpectrumAnalyzer::N / 2 * sizeof(float));
    const auto flags = pa_stream_flags_t(PA_STREAM_ADJUST_LATENCY | PA_STREAM_DONT_INHIBIT_AUTO_SUSPEND);
    if (pa_stream_connect_record(m_stream, source.constData(), &attr, flags) < 0) {
        dropStream();
    }
}

void AudioSpectrum::streamStateCallback(pa_stream *stream, void *userdata)
{
    auto *self = static_cast<AudioSpectrum *>(userdata);
    if (stream != self->m_stream) {
        return;
    }
    const pa_stream_state_t state = pa_stream_get_state(stream);
    if (state == PA_STREAM_FAILED || state == PA_STREAM_TERMINATED) {
        // The monitor went away (sink removed); look up the default again.
        QMetaObject::invokeMethod(
            self,
            [self, stream] {
                if (self->m_stream != stream) {
                    return;
                }
                self->dropStream();
                self->resetLevels();
                self->m_sinkName.clear();
                if (self->m_context && pa_context_get_state(self->m_context) == PA_CONTEXT_READY) {
                    release(pa_context_get_server_info(self->m_context, &AudioSpectrum::serverInfoCallback, self));
                }
            },
            Qt::QueuedConnection);
    }
}

void AudioSpectrum::readCallback(pa_stream *stream, size_t, void *userdata)
{
    auto *self = static_cast<AudioSpectrum *>(userdata);
    if (stream != self->m_stream || !self->m_analyzer) {
        return;
    }
    // Publish only once the stream is no longer touched: a QML handler that
    // reacts to levelsChanged may stop the capture.
    bool fresh = false;
    std::array<float, Bands> levels{};
    while (pa_stream_readable_size(stream) > 0) {
        const void *data = nullptr;
        size_t bytes = 0;
        if (pa_stream_peek(stream, &data, &bytes) < 0 || bytes == 0) {
            break;
        }
        if (data && bytes >= sizeof(float)) {
            fresh = self->m_analyzer->process(static_cast<const float *>(data), bytes / sizeof(float), levels) || fresh;
        }
        pa_stream_drop(stream);
    }
    if (fresh) {
        self->publish(levels);
    }
}

void AudioSpectrum::publish(const std::array<float, Bands> &levels)
{
    bool changed = false;
    for (int b = 0; b < Bands; ++b) {
        const qreal value = levels[b];
        if (m_levels[b] != value) {
            m_levels[b] = value;
            changed = true;
        }
    }
    if (changed) {
        Q_EMIT levelsChanged();
    }
}
