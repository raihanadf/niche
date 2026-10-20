#include "media/mediaplayer.h"

#include "kwinscript.h"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusVariant>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIcon>
#include <QImageReader>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>

#include <algorithm>

namespace
{
const QString mprisPrefix = QStringLiteral("org.mpris.MediaPlayer2.");
const QString mprisPath = QStringLiteral("/org/mpris/MediaPlayer2");
const QString rootInterface = QStringLiteral("org.mpris.MediaPlayer2");
const QString playerInterface = QStringLiteral("org.mpris.MediaPlayer2.Player");
const QString propertiesInterface = QStringLiteral("org.freedesktop.DBus.Properties");
const QString busService = QStringLiteral("org.freedesktop.DBus");
const QString busPath = QStringLiteral("/org/freedesktop/DBus");
const QString playingStatus = QStringLiteral("Playing");
const QString stoppedStatus = QStringLiteral("Stopped");
const QString noTrack = QStringLiteral("/org/mpris/MediaPlayer2/TrackList/NoTrack");

constexpr int holdForArtwork = 800; // niche: a new song without artwork waits 0.8 s
constexpr int clearAfter = 1500; // niche: a vanished track clears after 1.5 s
constexpr int artCacheLimit = 32;
constexpr qint64 artMaxBytes = 8 * 1024 * 1024;
constexpr int failedArtMemory = 16;

template<typename Handler>
void whenDone(QObject *context, const QDBusPendingCall &call, Handler handler)
{
    auto *watcher = new QDBusPendingCallWatcher(call, context);
    QObject::connect(watcher, &QDBusPendingCallWatcher::finished, context, [handler](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        handler(*w);
    });
}

QDBusMessage busCall(const QString &method)
{
    return QDBusMessage::createMethodCall(busService, busPath, busService, method);
}

QDBusMessage propertiesCall(const QString &owner, const QString &method)
{
    return QDBusMessage::createMethodCall(owner, mprisPath, propertiesInterface, method);
}

QVariantMap toMap(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusArgument>()) {
        return qdbus_cast<QVariantMap>(value.value<QDBusArgument>());
    }
    return value.toMap();
}

QString joined(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusArgument>()) {
        return qdbus_cast<QStringList>(value.value<QDBusArgument>()).join(QStringLiteral(", "));
    }
    if (value.metaType() == QMetaType::fromType<QStringList>()) {
        return value.toStringList().join(QStringLiteral(", "));
    }
    return value.toString();
}

QString objectPath(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusObjectPath>()) {
        return value.value<QDBusObjectPath>().path();
    }
    return value.toString();
}

bool validObjectPath(const QString &path)
{
    static const QRegularExpression pattern(QStringLiteral("^/([A-Za-z0-9_]+(/[A-Za-z0-9_]+)*)?$"));
    return pattern.match(path).hasMatch();
}

bool looksLikeBrowser(const QString &text)
{
    static const QStringList browsers{
        QStringLiteral("firefox"),         QStringLiteral("firefox-esr"),     QStringLiteral("chromium"),
        QStringLiteral("chromium-browser"), QStringLiteral("chrome"),         QStringLiteral("google-chrome"),
        QStringLiteral("brave"),           QStringLiteral("brave-browser"),   QStringLiteral("vivaldi"),
        QStringLiteral("msedge"),          QStringLiteral("microsoft-edge"),  QStringLiteral("opera"),
        QStringLiteral("librewolf"),       QStringLiteral("waterfox"),        QStringLiteral("floorp"),
        QStringLiteral("zen"),             QStringLiteral("zen-browser"),     QStringLiteral("epiphany"),
        QStringLiteral("falkon"),          QStringLiteral("konqueror"),       QStringLiteral("qutebrowser"),
        QStringLiteral("angelfish"),       QStringLiteral("mullvadbrowser"),  QStringLiteral("torbrowser"),
        QStringLiteral("plasma-browser-integration"),
    };
    static const QRegularExpression separators(QStringLiteral("[.\\s_]+"));
    const QStringList tokens = text.toLower().split(separators, Qt::SkipEmptyParts);
    return std::any_of(tokens.begin(), tokens.end(), [](const QString &token) {
        return browsers.contains(token);
    });
}

QString iconFromDesktopFile(const QString &entry)
{
    if (entry.isEmpty()) {
        return {};
    }
    const QString file = entry + QStringLiteral(".desktop");
    QString path = QStandardPaths::locate(QStandardPaths::ApplicationsLocation, file);
    if (path.isEmpty()) {
        path = QStandardPaths::locate(QStandardPaths::ApplicationsLocation, file.toLower());
    }
    if (path.isEmpty()) {
        return {};
    }
    QFile desktop(path);
    if (!desktop.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return {};
    }
    bool inEntry = false;
    while (!desktop.atEnd()) {
        const QByteArray line = desktop.readLine().trimmed();
        if (line.startsWith('[')) {
            if (inEntry) {
                break;
            }
            inEntry = line == QByteArrayLiteral("[Desktop Entry]");
            continue;
        }
        if (inEntry && line.startsWith("Icon=")) {
            return QString::fromUtf8(line.mid(5)).trimmed();
        }
    }
    return {};
}

QString playerIcon(const QString &entry, const QString &service)
{
    const QString name = service.mid(mprisPrefix.size()).section(QLatin1Char('.'), 0, 0).toLower();
    for (const QString &candidate : {iconFromDesktopFile(entry), entry, name}) {
        if (candidate.isEmpty()) {
            continue;
        }
        if (QDir::isAbsolutePath(candidate)) {
            if (QFileInfo::exists(candidate)) {
                return QUrl::fromLocalFile(candidate).toString();
            }
            continue;
        }
        if (QIcon::hasThemeIcon(candidate)) {
            return candidate;
        }
    }
    return QStringLiteral("audio-x-generic");
}

QString titleFromUrl(const QString &url)
{
    const QString name = QUrl(url).fileName();
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    return dot > 0 ? name.left(dot) : name;
}
}

MediaPlayer::MediaPlayer(QObject *parent)
    : QObject(parent)
{
    m_clock.start();
    m_cacheDir = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + QStringLiteral("/niche-kde/art");

    m_pendingDeadline.setSingleShot(true);
    m_pendingDeadline.setInterval(holdForArtwork);
    connect(&m_pendingDeadline, &QTimer::timeout, this, [this] {
        if (m_hasPending) {
            const Track held = m_pendingSong;
            commit(held);
        }
    });
    m_clearDelay.setSingleShot(true);
    m_clearDelay.setInterval(clearAfter);
    connect(&m_clearDelay, &QTimer::timeout, this, &MediaPlayer::clearTrack);
    // niche's playbackTimer: one position tick per second.
    m_ticker.setInterval(1000);
    connect(&m_ticker, &QTimer::timeout, this, &MediaPlayer::tick);

    QDBusConnection bus = QDBusConnection::sessionBus();
    bus.connect(busService, busPath, busService, QStringLiteral("NameOwnerChanged"), this, SLOT(onNameOwnerChanged(QString,QString,QString)));
    bus.connect(QString(),
                mprisPath,
                propertiesInterface,
                QStringLiteral("PropertiesChanged"),
                this,
                SLOT(onPropertiesChanged(QString,QVariantMap,QStringList)));
    bus.connect(QString(), mprisPath, playerInterface, QStringLiteral("Seeked"), this, SLOT(onSeeked(qlonglong)));

    whenDone(this, bus.asyncCall(busCall(QStringLiteral("ListNames"))), [this](const QDBusPendingCall &call) {
        const QDBusPendingReply<QStringList> reply = call;
        if (reply.isError()) {
            qWarning("niche: cannot list D-Bus names: %s", qPrintable(reply.error().message()));
            return;
        }
        const QStringList names = reply.value();
        for (const QString &name : names) {
            if (!name.startsWith(mprisPrefix)) {
                continue;
            }
            QDBusMessage owner = busCall(QStringLiteral("GetNameOwner"));
            owner << name;
            whenDone(this, QDBusConnection::sessionBus().asyncCall(owner), [this, name](const QDBusPendingCall &call) {
                const QDBusPendingReply<QString> reply = call;
                if (!reply.isError()) {
                    addPlayer(name, reply.value());
                }
            });
        }
    });
}

MediaPlayer::~MediaPlayer() = default;

void MediaPlayer::setIgnoresBrowsers(bool ignores)
{
    if (m_ignoresBrowsers == ignores) {
        return;
    }
    m_ignoresBrowsers = ignores;
    Q_EMIT ignoresBrowsersChanged();
    refresh();
}

// MARK: players

void MediaPlayer::onNameOwnerChanged(const QString &name, const QString &oldOwner, const QString &newOwner)
{
    if (!name.startsWith(mprisPrefix)) {
        return;
    }
    if (!oldOwner.isEmpty()) {
        removePlayer(name);
    }
    if (!newOwner.isEmpty()) {
        addPlayer(name, newOwner);
    }
}

void MediaPlayer::addPlayer(const QString &service, const QString &owner)
{
    if (owner.isEmpty()) {
        return;
    }
    // playerctld re-publishes whichever player is active under its own name.
    const QString suffix = service.mid(mprisPrefix.size());
    if (suffix == QLatin1String("playerctld") || suffix.startsWith(QLatin1String("playerctld."))) {
        return;
    }
    // One process can own several MPRIS names; follow it once.
    for (const auto &player : m_players) {
        if (player->service == service || player->owner == owner) {
            return;
        }
    }
    auto player = std::make_unique<Player>();
    player->service = service;
    player->owner = owner;
    player->activity = ++m_activity;
    player->positionStamp = now();
    player->browser = looksLikeBrowser(suffix);
    player->iconName = playerIcon(QString(), service);
    m_players.push_back(std::move(player));

    fetchRoot(owner);
    fetchPlayer(owner);
    QDBusMessage pid = busCall(QStringLiteral("GetConnectionUnixProcessID"));
    pid << owner;
    whenDone(this, QDBusConnection::sessionBus().asyncCall(pid), [this, owner](const QDBusPendingCall &call) {
        const QDBusPendingReply<uint> reply = call;
        if (Player *player = playerByOwner(owner); player && !reply.isError()) {
            player->pid = reply.value();
        }
    });
}

void MediaPlayer::removePlayer(const QString &service)
{
    const auto it = std::find_if(m_players.begin(), m_players.end(), [&](const auto &player) {
        return player->service == service;
    });
    if (it == m_players.end()) {
        return;
    }
    m_players.erase(it);
    refresh();
}

MediaPlayer::Player *MediaPlayer::playerByOwner(const QString &owner) const
{
    for (const auto &player : m_players) {
        if (player->owner == owner) {
            return player.get();
        }
    }
    return nullptr;
}

MediaPlayer::Player *MediaPlayer::current() const
{
    return m_currentOwner.isEmpty() ? nullptr : playerByOwner(m_currentOwner);
}

// niche shows the system's now-playing app; with several MPRIS players the
// closest rule is: the playing one (latest to start wins), else the one that
// was active most recently.
MediaPlayer::Player *MediaPlayer::pick() const
{
    Player *best = nullptr;
    for (const auto &candidate : m_players) {
        Player &player = *candidate;
        if (!player.rootKnown || !player.playerKnown || player.title.isEmpty() || player.status == stoppedStatus) {
            continue;
        }
        if (m_ignoresBrowsers && player.browser) {
            continue;
        }
        if (!best) {
            best = &player;
            continue;
        }
        const bool playing = player.status == playingStatus;
        const bool bestPlaying = best->status == playingStatus;
        if (playing != bestPlaying) {
            if (playing) {
                best = &player;
            }
        } else if (player.activity > best->activity) {
            best = &player;
        }
    }
    return best;
}

void MediaPlayer::fetchRoot(const QString &owner)
{
    QDBusMessage call = propertiesCall(owner, QStringLiteral("GetAll"));
    call << rootInterface;
    whenDone(this, QDBusConnection::sessionBus().asyncCall(call), [this, owner](const QDBusPendingCall &call) {
        Player *player = playerByOwner(owner);
        if (!player) {
            return;
        }
        const QDBusPendingReply<QVariantMap> reply = call;
        if (!reply.isError()) {
            applyRoot(*player, reply.value());
        }
        player->rootKnown = true;
        refresh();
    });
}

void MediaPlayer::fetchPlayer(const QString &owner)
{
    QDBusMessage call = propertiesCall(owner, QStringLiteral("GetAll"));
    call << playerInterface;
    whenDone(this, QDBusConnection::sessionBus().asyncCall(call), [this, owner](const QDBusPendingCall &call) {
        Player *player = playerByOwner(owner);
        if (!player) {
            return;
        }
        const QDBusPendingReply<QVariantMap> reply = call;
        if (!reply.isError()) {
            applyPlayer(*player, reply.value());
        }
        player->playerKnown = true;
        refresh();
    });
}

void MediaPlayer::fetchPosition(const QString &owner)
{
    QDBusMessage call = propertiesCall(owner, QStringLiteral("Get"));
    call << playerInterface << QStringLiteral("Position");
    whenDone(this, QDBusConnection::sessionBus().asyncCall(call), [this, owner](const QDBusPendingCall &call) {
        Player *player = playerByOwner(owner);
        const QDBusPendingReply<QDBusVariant> reply = call;
        if (!player || reply.isError()) {
            return;
        }
        player->positionUs = reply.value().variant().toLongLong();
        player->positionStamp = now();
        if (player->owner == m_currentOwner) {
            refresh();
        }
    });
}

void MediaPlayer::applyRoot(Player &player, const QVariantMap &properties)
{
    if (properties.contains(QStringLiteral("Identity"))) {
        player.identity = properties.value(QStringLiteral("Identity")).toString();
    }
    if (properties.contains(QStringLiteral("DesktopEntry"))) {
        player.desktopEntry = properties.value(QStringLiteral("DesktopEntry")).toString();
        player.iconName = playerIcon(player.desktopEntry, player.service);
    }
    if (properties.contains(QStringLiteral("CanRaise"))) {
        player.canRaise = properties.value(QStringLiteral("CanRaise")).toBool();
    }
    player.browser = looksLikeBrowser(player.service.mid(mprisPrefix.size())) || looksLikeBrowser(player.desktopEntry) || looksLikeBrowser(player.identity);
}

void MediaPlayer::applyPlayer(Player &player, const QVariantMap &properties)
{
    const qint64 stamp = now();
    const bool hasPosition = properties.contains(QStringLiteral("Position"));

    if (properties.contains(QStringLiteral("PlaybackStatus"))) {
        const QString status = properties.value(QStringLiteral("PlaybackStatus")).toString();
        if (status != player.status) {
            // Freeze the position under the old status before switching.
            player.positionUs = livePositionUs(player);
            player.positionStamp = stamp;
            if (status == playingStatus) {
                player.activity = ++m_activity;
            }
            player.status = status;
            if (!hasPosition && player.playerKnown) {
                fetchPosition(player.owner);
            }
        }
    }
    if (properties.contains(QStringLiteral("Metadata"))) {
        const QVariantMap metadata = toMap(properties.value(QStringLiteral("Metadata")));
        QString title = metadata.value(QStringLiteral("xesam:title")).toString().trimmed();
        if (title.isEmpty()) {
            title = titleFromUrl(metadata.value(QStringLiteral("xesam:url")).toString());
        }
        const QString artist = joined(metadata.value(QStringLiteral("xesam:artist"))).trimmed();
        const QString album = metadata.value(QStringLiteral("xesam:album")).toString().trimmed();
        const QString trackId = objectPath(metadata.value(QStringLiteral("mpris:trackid")));
        const bool changed = title != player.title || artist != player.artist || album != player.album || trackId != player.trackId;
        player.title = title;
        player.artist = artist;
        player.album = album;
        player.trackId = trackId;
        player.art = metadata.value(QStringLiteral("mpris:artUrl")).toString();
        player.lengthUs = std::max<qint64>(0, metadata.value(QStringLiteral("mpris:length")).toLongLong());
        if (changed && !hasPosition && player.playerKnown) {
            player.positionUs = 0;
            player.positionStamp = stamp;
            if (player.status == playingStatus) {
                player.activity = ++m_activity;
            }
            fetchPosition(player.owner);
        }
    }
    if (hasPosition) {
        player.positionUs = properties.value(QStringLiteral("Position")).toLongLong();
        player.positionStamp = stamp;
    }
    if (properties.contains(QStringLiteral("Rate"))) {
        // Rebase so the extrapolation switches rate from now on.
        player.positionUs = livePositionUs(player);
        player.positionStamp = stamp;
        const double rate = properties.value(QStringLiteral("Rate")).toDouble();
        player.rate = rate > 0 ? rate : 1;
    }
    if (properties.contains(QStringLiteral("CanSeek"))) {
        player.canSeek = properties.value(QStringLiteral("CanSeek")).toBool();
    }
    if (properties.contains(QStringLiteral("CanGoNext"))) {
        player.canGoNext = properties.value(QStringLiteral("CanGoNext")).toBool();
    }
    if (properties.contains(QStringLiteral("CanGoPrevious"))) {
        player.canGoPrevious = properties.value(QStringLiteral("CanGoPrevious")).toBool();
    }
    if (properties.contains(QStringLiteral("CanControl"))) {
        player.canControl = properties.value(QStringLiteral("CanControl")).toBool();
    }
    if (properties.contains(QStringLiteral("Shuffle"))) {
        player.hasShuffle = true;
        player.shuffle = properties.value(QStringLiteral("Shuffle")).toBool();
    }
}

void MediaPlayer::onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated)
{
    if (!calledFromDBus()) {
        return;
    }
    Player *player = playerByOwner(message().service());
    if (!player) {
        return;
    }
    if (interface == playerInterface) {
        if (!player->playerKnown) {
            return; // the pending GetAll brings the full state
        }
        applyPlayer(*player, changed);
        if (!invalidated.isEmpty()) {
            fetchPlayer(player->owner);
        }
    } else if (interface == rootInterface) {
        applyRoot(*player, changed);
        if (!invalidated.isEmpty()) {
            fetchRoot(player->owner);
        }
    } else {
        return;
    }
    refresh();
}

void MediaPlayer::onSeeked(qlonglong position)
{
    if (!calledFromDBus()) {
        return;
    }
    Player *player = playerByOwner(message().service());
    if (!player) {
        return;
    }
    player->positionUs = position;
    player->positionStamp = now();
    refresh();
}

qint64 MediaPlayer::livePositionUs(const Player &player) const
{
    if (player.status != playingStatus) {
        return player.positionUs;
    }
    return player.positionUs + qint64(double(now() - player.positionStamp) * 1000.0 * player.rate);
}

// MARK: shown track

void MediaPlayer::refresh()
{
    Player *player = pick();
    m_currentOwner = player ? player->owner : QString();
    if (!player) {
        if (m_hasTrack && !m_clearDelay.isActive()) {
            m_clearDelay.start();
        }
        return;
    }
    m_clearDelay.stop();

    setPlaying(player->status == playingStatus);
    setCapabilities(player->canSeek, player->canGoNext, player->canGoPrevious, player->canControl, player->hasShuffle);
    setShuffle(player->shuffle);
    setIdentity(player->identity);
    setIconName(player->iconName);
    m_baseMs = livePositionUs(*player) / 1000;
    m_baseStamp = now();
    m_rate = player->rate;

    Track next;
    next.title = player->title;
    next.artist = player->artist;
    next.album = player->album;
    next.lengthMs = player->lengthUs / 1000;
    next.art = resolveArt(player->art);

    const bool isNewSong = m_hasLastSong && !m_lastSong.isSameSong(next);
    if (isNewSong && next.art.isEmpty()) {
        if (!m_hasPending || !m_pendingSong.isSameSong(next)) {
            m_pendingDeadline.start();
        }
        m_pendingSong = next;
        m_hasPending = true;
        return;
    }
    commit(next);
}

void MediaPlayer::commit(const Track &next)
{
    m_hasPending = false;
    m_pendingDeadline.stop();
    // The token moves first so views can still read the outgoing song.
    if (m_hasLastSong && !m_lastSong.isSameSong(next)) {
        ++m_songChangeToken;
        Q_EMIT songChangeTokenChanged();
    }
    m_lastSong = next;
    m_hasLastSong = true;
    setTrackFields(next);
    setHasTrack(true);
    tick();
}

void MediaPlayer::clearTrack()
{
    m_hasPending = false;
    m_pendingDeadline.stop();
    setHasTrack(false);
    setPlaying(false);
    setTrackFields(Track());
    setPosition(0);
    setCapabilities(false, false, false, false, false);
    setShuffle(false);
    setIdentity(QString());
    setIconName(QString());
}

void MediaPlayer::tick()
{
    if (!m_hasTrack) {
        return;
    }
    const qint64 live = m_playing ? qint64(double(now() - m_baseStamp) * m_rate) : 0;
    qint64 position = std::max<qint64>(0, m_baseMs + live);
    if (m_length > 0) {
        position = std::min(position, m_length);
    }
    setPosition(position);
}

void MediaPlayer::updateTicking()
{
    if (m_hasTrack && m_playing) {
        if (!m_ticker.isActive()) {
            m_ticker.start();
        }
    } else {
        m_ticker.stop();
    }
}

// MARK: controls

void MediaPlayer::callPlayer(const QString &method, const QVariantList &arguments)
{
    Player *player = current();
    if (!player) {
        return;
    }
    QDBusMessage call = QDBusMessage::createMethodCall(player->owner, mprisPath, playerInterface, method);
    call.setArguments(arguments);
    QDBusConnection::sessionBus().asyncCall(call);
}

void MediaPlayer::playPause()
{
    callPlayer(QStringLiteral("PlayPause"));
}

void MediaPlayer::next()
{
    callPlayer(QStringLiteral("Next"));
}

void MediaPlayer::previous()
{
    callPlayer(QStringLiteral("Previous"));
}

void MediaPlayer::seek(qint64 ms)
{
    Player *player = current();
    if (!player || !m_hasTrack || !player->canSeek) {
        return;
    }
    qint64 target = std::max<qint64>(0, ms);
    if (m_length > 0) {
        target = std::min(target, m_length);
    }
    if (player->trackId != noTrack && validObjectPath(player->trackId)) {
        callPlayer(QStringLiteral("SetPosition"), {QVariant::fromValue(QDBusObjectPath(player->trackId)), QVariant::fromValue(qlonglong(target * 1000))});
    } else {
        callPlayer(QStringLiteral("Seek"), {QVariant::fromValue(qlonglong((target - m_position) * 1000))});
    }
    // Like niche, move the bar right away instead of waiting for Seeked.
    const qint64 stamp = now();
    player->positionUs = target * 1000;
    player->positionStamp = stamp;
    m_baseMs = target;
    m_baseStamp = stamp;
    tick();
}

void MediaPlayer::toggleShuffle()
{
    Player *player = current();
    if (!player || !player->hasShuffle) {
        return;
    }
    const bool shuffle = !player->shuffle;
    QDBusMessage call = propertiesCall(player->owner, QStringLiteral("Set"));
    call << playerInterface << QStringLiteral("Shuffle") << QVariant::fromValue(QDBusVariant(shuffle));
    QDBusConnection::sessionBus().asyncCall(call);
    player->shuffle = shuffle;
    setShuffle(shuffle);
}

void MediaPlayer::raise()
{
    Player *player = current();
    if (!player) {
        return;
    }
    if (player->canRaise) {
        QDBusConnection::sessionBus().asyncCall(QDBusMessage::createMethodCall(player->owner, mprisPath, rootInterface, QStringLiteral("Raise")));
        return;
    }
    // No MPRIS Raise: let KWin activate the player's window by pid, window
    // class or desktop file name.
    QStringList classes;
    for (const QString &name : {player->desktopEntry, player->service.mid(mprisPrefix.size()).section(QLatin1Char('.'), 0, 0)}) {
        if (!name.isEmpty()) {
            classes << name.toLower();
        }
    }
    const QString list = QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(classes)).toJson(QJsonDocument::Compact));
    KWinScript::runOnce(QStringLiteral(R"JS(
(function () {
    const pid = %1;
    const names = %2;
    const windows = workspace.windowList();
    for (let i = 0; i < windows.length; ++i) {
        const w = windows[i];
        if (!w.normalWindow) {
            continue;
        }
        const cls = String(w.resourceClass).toLowerCase();
        const desktop = String(w.desktopFileName || "").toLowerCase();
        if ((pid > 0 && w.pid === pid) || names.indexOf(cls) >= 0 || (desktop && names.indexOf(desktop) >= 0)) {
            w.minimized = false;
            workspace.activeWindow = w;
            return;
        }
    }
})();
)JS")
                             .arg(QString::number(player->pid), list));
}

// MARK: artwork

QString MediaPlayer::cachePath(const QString &source) const
{
    return m_cacheDir + QLatin1Char('/') + QString::fromLatin1(QCryptographicHash::hash(source.toUtf8(), QCryptographicHash::Sha1).toHex());
}

QUrl MediaPlayer::resolveArt(const QString &source)
{
    if (source.isEmpty()) {
        return {};
    }
    if (source == m_resolvedSource) {
        return m_resolvedArt;
    }
    QUrl resolved;
    const QUrl url(source);
    const QString scheme = url.scheme().toLower();
    if (scheme == QLatin1String("file")) {
        resolved = url;
    } else if (scheme.isEmpty() && QDir::isAbsolutePath(source)) {
        resolved = QUrl::fromLocalFile(source);
    } else if (scheme == QLatin1String("http") || scheme == QLatin1String("https") || scheme == QLatin1String("data")) {
        const QString path = cachePath(source);
        if (QFileInfo::exists(path)) {
            // Touch it so pruning keeps recently shown art.
            QFile file(path);
            if (file.open(QIODevice::ReadWrite)) {
                file.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
            }
            resolved = QUrl::fromLocalFile(path);
        } else if (scheme == QLatin1String("data")) {
            const int comma = source.indexOf(QLatin1Char(','));
            const bool base64 = comma > 0 && source.left(comma).endsWith(QLatin1String(";base64"));
            if (base64 && storeArt(source, QByteArray::fromBase64(source.mid(comma + 1).toLatin1()))) {
                resolved = QUrl::fromLocalFile(path);
            }
        } else if (!m_failedArt.contains(source)) {
            download(source);
        }
    }
    m_resolvedSource = source;
    m_resolvedArt = resolved;
    return resolved;
}

void MediaPlayer::download(const QString &source)
{
    if (m_downloading == source && m_reply) {
        return;
    }
    if (m_reply) {
        // Clear first: abort() finishes the reply synchronously.
        QNetworkReply *previous = m_reply;
        m_reply = nullptr;
        previous->abort();
    }
    if (!m_network) {
        m_network = new QNetworkAccessManager(this);
    }
    QNetworkRequest request{QUrl(source)};
    request.setTransferTimeout(10000);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    QNetworkReply *reply = m_network->get(request);
    m_reply = reply;
    m_downloading = source;
    connect(reply, &QNetworkReply::downloadProgress, reply, [reply](qint64 received, qint64 total) {
        if (received > artMaxBytes || total > artMaxBytes) {
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, source] {
        reply->deleteLater();
        if (reply != m_reply) {
            return;
        }
        m_reply = nullptr;
        m_downloading.clear();
        const QByteArray data = reply->error() == QNetworkReply::NoError ? reply->readAll() : QByteArray();
        if (!storeArt(source, data)) {
            m_failedArt.append(source);
            while (m_failedArt.size() > failedArtMemory) {
                m_failedArt.removeFirst();
            }
        }
        if (m_resolvedSource == source) {
            m_resolvedSource.clear();
            m_resolvedArt.clear();
        }
        refresh();
    });
}

bool MediaPlayer::storeArt(const QString &source, const QByteArray &data)
{
    if (data.isEmpty() || data.size() > artMaxBytes) {
        return false;
    }
    QByteArray copy = data;
    QBuffer buffer(&copy);
    if (!buffer.open(QIODevice::ReadOnly) || QImageReader(&buffer).format().isEmpty()) {
        return false;
    }
    if (!QDir().mkpath(m_cacheDir)) {
        return false;
    }
    QSaveFile file(cachePath(source));
    if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size() || !file.commit()) {
        return false;
    }
    pruneCache();
    return true;
}

void MediaPlayer::pruneCache() const
{
    const QFileInfoList files = QDir(m_cacheDir).entryInfoList(QDir::Files | QDir::NoDotAndDotDot, QDir::Time);
    for (qsizetype i = artCacheLimit; i < files.size(); ++i) {
        QFile::remove(files.at(i).absoluteFilePath());
    }
}

// MARK: property setters

void MediaPlayer::setHasTrack(bool hasTrack)
{
    if (m_hasTrack != hasTrack) {
        m_hasTrack = hasTrack;
        Q_EMIT hasTrackChanged();
    }
    updateTicking();
}

void MediaPlayer::setPlaying(bool playing)
{
    if (m_playing != playing) {
        m_playing = playing;
        Q_EMIT playingChanged();
    }
    updateTicking();
}

void MediaPlayer::setPosition(qint64 position)
{
    if (m_position != position) {
        m_position = position;
        Q_EMIT positionChanged();
    }
}

void MediaPlayer::setTrackFields(const Track &track)
{
    if (m_title != track.title) {
        m_title = track.title;
        Q_EMIT titleChanged();
    }
    if (m_artist != track.artist) {
        m_artist = track.artist;
        Q_EMIT artistChanged();
    }
    if (m_album != track.album) {
        m_album = track.album;
        Q_EMIT albumChanged();
    }
    if (m_length != track.lengthMs) {
        m_length = track.lengthMs;
        Q_EMIT lengthChanged();
    }
    if (m_artUrl != track.art) {
        m_artUrl = track.art;
        Q_EMIT artUrlChanged();
    }
}

void MediaPlayer::setCapabilities(bool seek, bool next, bool previous, bool control, bool shuffle)
{
    if (m_canSeek == seek && m_canGoNext == next && m_canGoPrevious == previous && m_canControl == control && m_canShuffle == shuffle) {
        return;
    }
    m_canSeek = seek;
    m_canGoNext = next;
    m_canGoPrevious = previous;
    m_canControl = control;
    m_canShuffle = shuffle;
    Q_EMIT capabilitiesChanged();
}

void MediaPlayer::setShuffle(bool shuffle)
{
    if (m_shuffle != shuffle) {
        m_shuffle = shuffle;
        Q_EMIT shuffleChanged();
    }
}

void MediaPlayer::setIdentity(const QString &identity)
{
    if (m_identity != identity) {
        m_identity = identity;
        Q_EMIT identityChanged();
    }
}

void MediaPlayer::setIconName(const QString &iconName)
{
    if (m_iconName != iconName) {
        m_iconName = iconName;
        Q_EMIT iconNameChanged();
    }
}
