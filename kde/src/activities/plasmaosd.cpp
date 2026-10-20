#include "activities/plasmaosd.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QList>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>

namespace
{
const QByteArray Group = QByteArrayLiteral("[OSD]");
const QByteArray Key = QByteArrayLiteral("Enabled");
const QByteArray DisabledLine = QByteArrayLiteral("Enabled=false");

QString configPath()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/plasmashellrc");
}

bool isGroupHeader(const QByteArray &trimmed)
{
    return trimmed.startsWith('[') && trimmed.endsWith(']');
}

// True when the (trimmed) line assigns the plain "Enabled" key.
bool isEnabledKey(const QByteArray &trimmed)
{
    const qsizetype equals = trimmed.indexOf('=');
    return equals > 0 && trimmed.left(equals).trimmed() == Key;
}

QList<QByteArray> readLines()
{
    QFile file(configPath());
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    QList<QByteArray> lines = file.readAll().split('\n');
    // split() leaves an empty last element for a trailing newline.
    if (!lines.isEmpty() && lines.constLast().isEmpty()) {
        lines.removeLast();
    }
    return lines;
}

bool editFile(bool enabled)
{
    QList<QByteArray> lines = readLines();
    qsizetype header = -1;
    bool written = false;
    bool inGroup = false;
    for (qsizetype i = 0; i < lines.size();) {
        const QByteArray trimmed = lines.at(i).trimmed();
        if (isGroupHeader(trimmed)) {
            inGroup = trimmed == Group;
            if (inGroup && header < 0) {
                header = i;
            }
            ++i;
            continue;
        }
        if (inGroup && isEnabledKey(trimmed)) {
            if (!enabled && !written) {
                lines[i] = DisabledLine;
                written = true;
                ++i;
            } else {
                lines.removeAt(i);
            }
            continue;
        }
        ++i;
    }
    if (!enabled && !written) {
        if (header >= 0) {
            lines.insert(header + 1, DisabledLine);
        } else {
            if (!lines.isEmpty() && !lines.constLast().trimmed().isEmpty()) {
                lines.append(QByteArray());
            }
            lines.append(Group);
            lines.append(DisabledLine);
        }
    }

    QDir().mkpath(QFileInfo(configPath()).absolutePath());
    QSaveFile file(configPath());
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning("niche: cannot write %s", qPrintable(configPath()));
        return false;
    }
    for (const QByteArray &line : std::as_const(lines)) {
        file.write(line);
        file.write("\n");
    }
    return file.commit();
}
}

namespace PlasmaOsd
{
bool isEnabled()
{
    bool inGroup = false;
    bool enabled = true;
    for (const QByteArray &line : readLines()) {
        const QByteArray trimmed = line.trimmed();
        if (isGroupHeader(trimmed)) {
            inGroup = trimmed == Group;
        } else if (inGroup && isEnabledKey(trimmed)) {
            const QByteArray value = trimmed.mid(trimmed.indexOf('=') + 1).trimmed().toLower();
            enabled = !(value == "false" || value == "0" || value == "off" || value == "no");
        }
    }
    return enabled;
}

void setEnabled(bool enabled, QObject *context)
{
    const QString tool = QStandardPaths::findExecutable(QStringLiteral("kwriteconfig6"));
    if (tool.isEmpty()) {
        editFile(enabled);
        return;
    }
    QStringList arguments{QStringLiteral("--file"),
                          QStringLiteral("plasmashellrc"),
                          QStringLiteral("--group"),
                          QStringLiteral("OSD"),
                          QStringLiteral("--key"),
                          QStringLiteral("Enabled")};
    if (enabled) {
        arguments << QStringLiteral("--delete");
    } else {
        arguments << QStringLiteral("--type") << QStringLiteral("bool") << QStringLiteral("false");
    }
    auto *process = new QProcess(context);
    process->setProcessChannelMode(QProcess::ForwardedErrorChannel);
    process->setStandardOutputFile(QProcess::nullDevice());
    QObject::connect(process, &QProcess::finished, process, [process, enabled](int code, QProcess::ExitStatus status) {
        process->deleteLater();
        if (status != QProcess::NormalExit || code != 0) {
            editFile(enabled);
        }
    });
    QObject::connect(process, &QProcess::errorOccurred, process, [process, enabled](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            process->deleteLater();
            editFile(enabled);
        }
    });
    process->start(tool, arguments);
}

void restartShell()
{
    QString systemctl = QStandardPaths::findExecutable(QStringLiteral("systemctl"));
    if (systemctl.isEmpty()) {
        systemctl = QStringLiteral("systemctl");
    }
    QProcess::startDetached(systemctl, {QStringLiteral("--user"), QStringLiteral("restart"), QStringLiteral("plasma-plasmashell.service")});
}
}
