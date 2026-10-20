#pragma once

#include <QString>

// Brings an agent session to the front (niche's AgentMonitor.focus(pid:)).
namespace AgentFocus
{
// Blocking; run on a worker thread. Switches the most recent tmux client to the
// pane running `pid`, selects the konsole tab / kitty window that hosts it, and
// returns the KWin script that activates the terminal window. The caller runs
// the script on the GUI thread with KWinScript::runOnce.
QString prepare(qint64 pid);
}
