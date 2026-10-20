#include "settings.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QStandardPaths>

namespace
{
const QStringList builtIns = {QStringLiteral("pyramid-head"), QStringLiteral("cat"), QStringLiteral("ghost"), QStringLiteral("cassette"),
                              QStringLiteral("campfire")};
constexpr int maxFrames = 300;
const QString idleKey = QStringLiteral("general/idleImage");
}

Settings::Settings(QObject *parent)
    : QObject(parent)
    , m_store(QStringLiteral("niche-kde"), QStringLiteral("niche-kde"))
{
    loadIdleArt();
}

QString Settings::version() const
{
    return QStringLiteral(NICHE_VERSION);
}

QString Settings::autostartFile()
{
    return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation) + QStringLiteral("/autostart/org.niche.Island.desktop");
}

bool Settings::openAtLogin() const
{
    return QFile::exists(autostartFile());
}

void Settings::setOpenAtLogin(bool on)
{
    if (on == openAtLogin()) {
        return;
    }
    const QString path = autostartFile();
    if (on) {
        // Prefer a stable path (on PATH, or the symlink it was launched
        // through) over the nix store path, which changes on every rebuild.
        QString exec = QStandardPaths::findExecutable(QStringLiteral("niche-kde"));
        const QString launched = QCoreApplication::arguments().value(0);
        if (exec.isEmpty() && QFileInfo(launched).isAbsolute() && QFileInfo::exists(launched)) {
            exec = launched;
        }
        if (exec.isEmpty()) {
            exec = QCoreApplication::applicationFilePath();
        }
        QDir().mkpath(QFileInfo(path).absolutePath());
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            qWarning("niche: cannot write %s", qPrintable(path));
            return;
        }
        file.write(QStringLiteral("[Desktop Entry]\n"
                                  "Type=Application\n"
                                  "Name=niche\n"
                                  "Exec=%1\n"
                                  "Icon=niche-kde\n"
                                  "X-KDE-autostart-phase=2\n")
                       .arg(exec)
                       .toUtf8());
    } else {
        QFile::remove(path);
    }
    Q_EMIT openAtLoginChanged();
}

QStringList Settings::builtInArt() const
{
    return builtIns;
}

QUrl Settings::builtInUrl(const QString &name)
{
    return QUrl(QStringLiteral("qrc:/qt/qml/Niche/assets/idle/%1.gif").arg(name));
}

QString Settings::artFolder()
{
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
}

QString Settings::idleBuiltIn() const
{
    const QString name = m_store.value(idleKey).toString();
    return name.startsWith(QLatin1String("builtin:")) ? name.mid(8) : QString();
}

QUrl Settings::idleArt() const
{
    return m_idleArt;
}

QRectF Settings::idleArtCrop() const
{
    return m_idleCrop;
}

QRectF Settings::cropFor(const QUrl &url)
{
    const QString path = url.scheme() == QLatin1String("qrc") ? QLatin1Char(':') + url.path() : url.toLocalFile();
    QImageReader reader(path);
    const QSize size = reader.size();
    if (!size.isValid() || size.isEmpty()) {
        return {0, 0, 1, 1};
    }
    int minX = size.width(), minY = size.height(), maxX = -1, maxY = -1;
    for (int frame = 0; frame < maxFrames; ++frame) {
        QImage image = reader.read();
        if (image.isNull()) {
            break;
        }
        image = image.convertToFormat(QImage::Format_ARGB32);
        for (int y = 0; y < image.height(); ++y) {
            const auto *line = reinterpret_cast<const QRgb *>(image.constScanLine(y));
            for (int x = 0; x < image.width(); ++x) {
                if (qAlpha(line[x]) > 16) {
                    minX = std::min(minX, x);
                    maxX = std::max(maxX, x);
                    minY = std::min(minY, y);
                    maxY = std::max(maxY, y);
                }
            }
        }
        if (!reader.supportsAnimation() || !reader.jumpToNextImage()) {
            break;
        }
    }
    if (maxX < minX) {
        return {0, 0, 1, 1};
    }
    const qreal w = maxX - minX + 1, h = maxY - minY + 1, side = std::max(w, h);
    const qreal x = minX - (side - w) / 2, y = minY - (side - h) / 2;
    return {x / size.width(), y / size.height(), side / size.width(), side / size.height()};
}

void Settings::loadIdleArt()
{
    const QString name = m_store.value(idleKey).toString();
    QUrl url;
    if (name.startsWith(QLatin1String("builtin:"))) {
        url = builtInUrl(name.mid(8));
    } else if (!name.isEmpty() && QFile::exists(artFolder() + QLatin1Char('/') + name)) {
        url = QUrl::fromLocalFile(artFolder() + QLatin1Char('/') + name);
    }
    m_idleArt = url;
    m_idleCrop = url.isEmpty() ? QRectF(0, 0, 1, 1) : cropFor(url);
    Q_EMIT idleArtChanged();
}

void Settings::removeIdleCopy()
{
    const QString name = m_store.value(idleKey).toString();
    if (!name.isEmpty() && !name.startsWith(QLatin1String("builtin:"))) {
        QFile::remove(artFolder() + QLatin1Char('/') + name);
    }
}

void Settings::setIdleBuiltIn(const QString &name)
{
    if (!builtIns.contains(name)) {
        return;
    }
    removeIdleCopy();
    m_store.setValue(idleKey, QStringLiteral("builtin:") + name);
    loadIdleArt();
}

bool Settings::setIdleImage(const QUrl &file)
{
    const QString source = file.toLocalFile();
    QImageReader probe(source);
    if (!probe.canRead()) {
        return false;
    }
    const QString folder = artFolder();
    QDir().mkpath(folder);
    const QString name = QStringLiteral("idle.") + QFileInfo(source).suffix().toLower();
    for (const QString &old : QDir(folder).entryList({QStringLiteral("idle.*")}, QDir::Files)) {
        QFile::remove(folder + QLatin1Char('/') + old);
    }
    if (!QFile::copy(source, folder + QLatin1Char('/') + name)) {
        qWarning("niche: could not keep the island picture %s", qPrintable(source));
        return false;
    }
    m_store.setValue(idleKey, name);
    loadIdleArt();
    return true;
}

void Settings::clearIdleImage()
{
    removeIdleCopy();
    m_store.remove(idleKey);
    loadIdleArt();
}

void Settings::toggleActivity(const QString &kind, bool on)
{
    QStringList disabled = disabledActivities();
    disabled.removeAll(kind);
    if (!on) {
        disabled.append(kind);
    }
    setDisabledActivities(disabled);
}
