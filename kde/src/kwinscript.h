#pragma once

#include <QString>

// Runs JavaScript inside KWin through its Scripting D-Bus API. Window
// management (activating a window, reading fullscreen state) is only reachable
// this way on Wayland.
namespace KWinScript
{
// Loads `source` as a script named `pluginName`, starts it, and keeps it loaded
// until unload(pluginName). An already loaded script of that name is replaced.
void load(const QString &pluginName, const QString &source);

// Unloads a script started with load().
void unload(const QString &pluginName);

// Runs `source` once and unloads it a moment later. Asynchronous; never blocks.
void runOnce(const QString &source);
}
