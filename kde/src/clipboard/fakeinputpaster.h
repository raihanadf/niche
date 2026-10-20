#pragma once

#include <QMetaObject>

#include <cstdint>

struct wl_display;
struct wl_event_queue;
struct wl_registry;
struct org_kde_kwin_fake_input;

// Sends a Ctrl+V key chord to the focused window through KWin's
// org_kde_kwin_fake_input, the Wayland stand-in for niche's CGEvent post.
// Binds on Qt's wl_display with a private event queue so it never dispatches
// (or blocks on) Qt's own queue. KWin only advertises the global to clients
// whose desktop file lists it in X-KDE-Wayland-Interfaces.
class FakeInputPaster
{
public:
    FakeInputPaster();
    ~FakeInputPaster();

    FakeInputPaster(const FakeInputPaster &) = delete;
    FakeInputPaster &operator=(const FakeInputPaster &) = delete;

    // True when the fake input global was bound and authenticated.
    bool isAvailable() const
    {
        return m_input != nullptr;
    }

    // Presses and releases Left Ctrl + V.
    void pasteShortcut();

    // Drops the Wayland objects. Must run while Qt's display is still alive
    // (called from aboutToQuit and the destructor; idempotent).
    void release();

private:
    static void handleGlobal(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version);
    static void handleGlobalRemove(void *data, wl_registry *registry, uint32_t name);

    wl_display *m_display = nullptr;
    wl_event_queue *m_queue = nullptr;
    org_kde_kwin_fake_input *m_input = nullptr;
    uint32_t m_version = 0;
    QMetaObject::Connection m_quitConnection;
};
