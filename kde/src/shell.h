#pragma once

#include <QObject>
#include <QPointer>
#include <QRectF>
#include <QStringList>

class QQmlEngine;
class QQuickWindow;
class QScreen;
class KStatusNotifierItem;

// Owns the island's overlay surface and everything around it: the layer-shell
// setup, the input region, keyboard grabs for the clipboard picker, hiding
// under fullscreen windows, screen lock state, the tray item and the settings
// window. Exported on D-Bus as org.niche.Island /Shell so the KWin script and a
// second launch can reach it.
class Shell : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.niche.Shell")
    Q_PROPERTY(bool fullscreen READ fullscreen NOTIFY fullscreenChanged)
    Q_PROPERTY(bool locked READ locked NOTIFY lockedChanged)
    Q_PROPERTY(bool keyboardGrab READ keyboardGrab WRITE setKeyboardGrab NOTIFY keyboardGrabChanged)
    Q_PROPERTY(bool showInTray READ showInTray WRITE setShowInTray NOTIFY showInTrayChanged)

public:
    explicit Shell(QQmlEngine *engine, QObject *parent = nullptr);
    ~Shell() override;

    // Turns the QML root window into a top-center overlay layer surface and
    // shows it.
    void attach(QQuickWindow *window);

    bool fullscreen() const;
    bool locked() const;
    bool keyboardGrab() const;
    void setKeyboardGrab(bool grab);
    bool showInTray() const;
    void setShowInTray(bool show);

    // Region of the window that takes pointer input; the rest clicks through.
    Q_INVOKABLE void setInputRect(const QRectF &rect);
    // niche's malloc_zone_pressure_relief after closing: give freed heap back
    // to the system once the open views are torn down.
    Q_INVOKABLE void relieveMemory();

public Q_SLOTS:
    Q_SCRIPTABLE void openSettings();
    Q_SCRIPTABLE void quit();
    // Called by the KWin script: comma-separated output names whose topmost
    // window is fullscreen.
    Q_SCRIPTABLE void setFullscreenOutputs(const QString &outputs);
    // Called by the KWin script: name of Plasma's primary output.
    Q_SCRIPTABLE void setPrimaryOutput(const QString &output);
    // Called by the KWin script: internalId of the last active window that
    // isn't the island.
    Q_SCRIPTABLE void setLastActiveWindow(const QString &internalId);

Q_SIGNALS:
    void fullscreenChanged();
    void lockedChanged();
    void keyboardGrabChanged();
    void showInTrayChanged();

private Q_SLOTS:
    void screenSaverChanged(bool active);

private:
    QScreen *primaryScreen() const;
    void placeOnPrimary();
    void updateVisibility();
    void loadFullscreenScript();

    QQmlEngine *m_engine;
    QPointer<QQuickWindow> m_window;
    QPointer<QObject> m_settingsWindow;
    KStatusNotifierItem *m_tray = nullptr;
    QStringList m_fullscreenOutputs;
    QString m_primaryOutput;
    QString m_lastActiveWindow;
    bool m_placed = false;
    bool m_fullscreen = false;
    bool m_locked = false;
    bool m_keyboardGrab = false;
    bool m_showInTray = true;
};
