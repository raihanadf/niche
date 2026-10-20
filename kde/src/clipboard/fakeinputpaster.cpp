#include "fakeinputpaster.h"

#include "wayland-fake-input-client-protocol.h"

#include <QGuiApplication>
#include <QtGui/qguiapplication_platform.h>

#include <linux/input-event-codes.h>
#include <wayland-client.h>

#include <algorithm>
#include <cstring>

namespace
{
// keyboard_key arrived in version 4; destroy (a real destructor request) in 5.
constexpr uint32_t minVersion = 4;
constexpr uint32_t maxVersion = 5;
}

FakeInputPaster::FakeInputPaster()
{
    if (!qGuiApp) {
        return;
    }
    auto *wayland = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
    if (!wayland || !wayland->display()) {
        return;
    }
    m_display = wayland->display();
    m_queue = wl_display_create_queue(m_display);

    // Route the registry (and everything bound from it) to our own queue.
    auto *wrapper = static_cast<wl_display *>(wl_proxy_create_wrapper(m_display));
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(wrapper), m_queue);
    wl_registry *registry = wl_display_get_registry(wrapper);
    wl_proxy_wrapper_destroy(wrapper);

    static const wl_registry_listener listener = {
        &FakeInputPaster::handleGlobal,
        &FakeInputPaster::handleGlobalRemove,
    };
    wl_registry_add_listener(registry, &listener, this);
    wl_display_roundtrip_queue(m_display, m_queue);
    wl_registry_destroy(registry);

    if (!m_input) {
        wl_event_queue_destroy(m_queue);
        m_queue = nullptr;
        m_display = nullptr;
        return;
    }
    org_kde_kwin_fake_input_authenticate(m_input, "niche", "paste clipboard items");
    wl_display_flush(m_display);

    // Qt tears the display down with the application; let go of it first.
    m_quitConnection = QObject::connect(qGuiApp, &QCoreApplication::aboutToQuit, qGuiApp, [this] {
        release();
    });
}

FakeInputPaster::~FakeInputPaster()
{
    release();
}

void FakeInputPaster::handleGlobal(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version)
{
    auto *self = static_cast<FakeInputPaster *>(data);
    if (self->m_input || version < minVersion || std::strcmp(interface, org_kde_kwin_fake_input_interface.name) != 0) {
        return;
    }
    self->m_version = std::min(version, maxVersion);
    self->m_input = static_cast<org_kde_kwin_fake_input *>(wl_registry_bind(registry, name, &org_kde_kwin_fake_input_interface, self->m_version));
}

void FakeInputPaster::handleGlobalRemove(void *data, wl_registry *registry, uint32_t name)
{
    Q_UNUSED(data)
    Q_UNUSED(registry)
    Q_UNUSED(name)
}

void FakeInputPaster::pasteShortcut()
{
    if (!m_input) {
        return;
    }
    org_kde_kwin_fake_input_keyboard_key(m_input, KEY_LEFTCTRL, WL_KEYBOARD_KEY_STATE_PRESSED);
    org_kde_kwin_fake_input_keyboard_key(m_input, KEY_V, WL_KEYBOARD_KEY_STATE_PRESSED);
    org_kde_kwin_fake_input_keyboard_key(m_input, KEY_V, WL_KEYBOARD_KEY_STATE_RELEASED);
    org_kde_kwin_fake_input_keyboard_key(m_input, KEY_LEFTCTRL, WL_KEYBOARD_KEY_STATE_RELEASED);
    wl_display_flush(m_display);
}

void FakeInputPaster::release()
{
    if (m_input) {
        if (m_version >= 5) {
            org_kde_kwin_fake_input_destroy(m_input);
        } else {
            wl_proxy_destroy(reinterpret_cast<wl_proxy *>(m_input));
        }
        m_input = nullptr;
        wl_display_flush(m_display);
    }
    if (m_queue) {
        wl_event_queue_destroy(m_queue);
        m_queue = nullptr;
    }
    m_display = nullptr;
    QObject::disconnect(m_quitConnection);
}
