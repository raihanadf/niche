#pragma once

#include <QObject>

// Plasma's own volume / brightness OSD. plasmashell shows it unless
// `[OSD] Enabled=false` is set in plasmashellrc, which it reads at startup.
// niche hides the macOS HUD by swallowing media keys; on Plasma the closest
// equivalent is turning that OSD off.
namespace PlasmaOsd
{
// Value of `[OSD] Enabled` in ~/.config/plasmashellrc (default true).
bool isEnabled();

// Writes the key: `Enabled=false`, or removes it to restore the default.
// Uses kwriteconfig6 when available, else edits the file in place keeping
// every other group and key untouched. Asynchronous when kwriteconfig6 runs.
void setEnabled(bool enabled, QObject *context);

// Restarts plasmashell (detached) so it picks the new value up.
void restartShell();
}
