#pragma once

#include <QDBusContext>
#include <QElapsedTimer>
#include <QNetworkReply>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

#include <memory>
#include <vector>

class QNetworkAccessManager;

// Now playing over MPRIS (niche's MusicPlayer, which reads macOS's
// MediaRemote). Follows every org.mpris.MediaPlayer2.* player on the session
// bus and shows one: the playing one, else the one active most recently.
//
// Song changes follow niche: a new song without artwork is held back up to
// 0.8 s so title and art swap together, and a vanished track is cleared only
// after 1.5 s. songChangeToken increments (and is notified) *before* the new
// song's title/artist/album/artUrl are published, so views can snapshot the
// outgoing song in their handler.
class MediaPlayer : public QObject, protected QDBusContext
{
    Q_OBJECT
    Q_PROPERTY(bool hasTrack READ hasTrack NOTIFY hasTrackChanged)
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    Q_PROPERTY(QString artist READ artist NOTIFY artistChanged)
    Q_PROPERTY(QString album READ album NOTIFY albumChanged)
    Q_PROPERTY(QUrl artUrl READ artUrl NOTIFY artUrlChanged)
    Q_PROPERTY(qint64 length READ length NOTIFY lengthChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(bool canSeek READ canSeek NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool canGoNext READ canGoNext NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool canGoPrevious READ canGoPrevious NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool canControl READ canControl NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool canShuffle READ canShuffle NOTIFY capabilitiesChanged)
    Q_PROPERTY(bool shuffle READ shuffle NOTIFY shuffleChanged)
    Q_PROPERTY(QString identity READ identity NOTIFY identityChanged)
    Q_PROPERTY(QString iconName READ iconName NOTIFY iconNameChanged)
    Q_PROPERTY(int songChangeToken READ songChangeToken NOTIFY songChangeTokenChanged)
    // niche never shows browser media (tabs report now-playing for any video).
    Q_PROPERTY(bool ignoresBrowsers READ ignoresBrowsers WRITE setIgnoresBrowsers NOTIFY ignoresBrowsersChanged)

public:
    explicit MediaPlayer(QObject *parent = nullptr);
    ~MediaPlayer() override;

    bool hasTrack() const { return m_hasTrack; }
    bool playing() const { return m_playing; }
    QString title() const { return m_title; }
    QString artist() const { return m_artist; }
    QString album() const { return m_album; }
    QUrl artUrl() const { return m_artUrl; }
    qint64 length() const { return m_length; }
    qint64 position() const { return m_position; }
    bool canSeek() const { return m_canSeek; }
    bool canGoNext() const { return m_canGoNext; }
    bool canGoPrevious() const { return m_canGoPrevious; }
    bool canControl() const { return m_canControl; }
    bool canShuffle() const { return m_canShuffle; }
    bool shuffle() const { return m_shuffle; }
    QString identity() const { return m_identity; }
    QString iconName() const { return m_iconName; }
    int songChangeToken() const { return m_songChangeToken; }
    bool ignoresBrowsers() const { return m_ignoresBrowsers; }
    void setIgnoresBrowsers(bool ignores);

    Q_INVOKABLE void playPause();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    // Absolute position in milliseconds.
    Q_INVOKABLE void seek(qint64 ms);
    Q_INVOKABLE void toggleShuffle();
    // Brings the player's window forward (MPRIS Raise, else KWin).
    Q_INVOKABLE void raise();

Q_SIGNALS:
    void hasTrackChanged();
    void playingChanged();
    void titleChanged();
    void artistChanged();
    void albumChanged();
    void artUrlChanged();
    void lengthChanged();
    void positionChanged();
    void capabilitiesChanged();
    void shuffleChanged();
    void identityChanged();
    void iconNameChanged();
    void songChangeTokenChanged();
    void ignoresBrowsersChanged();

private Q_SLOTS:
    void onNameOwnerChanged(const QString &name, const QString &oldOwner, const QString &newOwner);
    void onPropertiesChanged(const QString &interface, const QVariantMap &changed, const QStringList &invalidated);
    void onSeeked(qlonglong position);

private:
    struct Player {
        QString service;
        QString owner;
        QString identity;
        QString desktopEntry;
        QString iconName;
        bool canRaise = false;
        bool rootKnown = false;
        bool playerKnown = false;
        bool browser = false;
        quint32 pid = 0;

        QString status;
        QString title;
        QString artist;
        QString album;
        QString art;
        QString trackId;
        qint64 lengthUs = 0;
        qint64 positionUs = 0;
        qint64 positionStamp = 0;
        double rate = 1;
        bool canSeek = false;
        bool canGoNext = false;
        bool canGoPrevious = false;
        bool canControl = false;
        bool hasShuffle = false;
        bool shuffle = false;
        quint64 activity = 0;
    };

    struct Track {
        QString title;
        QString artist;
        QString album;
        qint64 lengthMs = 0;
        QUrl art;

        bool isSameSong(const Track &other) const { return title == other.title && artist == other.artist && album == other.album; }
    };

    void addPlayer(const QString &service, const QString &owner);
    void removePlayer(const QString &service);
    Player *playerByOwner(const QString &owner) const;
    Player *current() const;
    Player *pick() const;

    void fetchRoot(const QString &owner);
    void fetchPlayer(const QString &owner);
    void fetchPosition(const QString &owner);
    void applyRoot(Player &player, const QVariantMap &properties);
    void applyPlayer(Player &player, const QVariantMap &properties);
    void callPlayer(const QString &method, const QVariantList &arguments = {});

    qint64 now() const { return m_clock.elapsed(); }
    qint64 livePositionUs(const Player &player) const;

    void refresh();
    void commit(const Track &next);
    void clearTrack();
    void tick();
    void updateTicking();

    QUrl resolveArt(const QString &source);
    QString cachePath(const QString &source) const;
    void download(const QString &source);
    bool storeArt(const QString &source, const QByteArray &data);
    void pruneCache() const;

    void setHasTrack(bool hasTrack);
    void setPlaying(bool playing);
    void setPosition(qint64 position);
    void setTrackFields(const Track &track);
    void setCapabilities(bool seek, bool next, bool previous, bool control, bool shuffle);
    void setShuffle(bool shuffle);
    void setIdentity(const QString &identity);
    void setIconName(const QString &iconName);

    std::vector<std::unique_ptr<Player>> m_players;
    QString m_currentOwner;
    quint64 m_activity = 0;
    QElapsedTimer m_clock;

    // Position extrapolation for the shown player (niche's elapsedAtTimestamp,
    // timestamp and rate).
    qint64 m_baseMs = 0;
    qint64 m_baseStamp = 0;
    double m_rate = 1;

    bool m_hasLastSong = false;
    Track m_lastSong;
    bool m_hasPending = false;
    Track m_pendingSong;
    QTimer m_pendingDeadline;
    QTimer m_clearDelay;
    QTimer m_ticker;

    QNetworkAccessManager *m_network = nullptr;
    QPointer<QNetworkReply> m_reply;
    QString m_downloading;
    QStringList m_failedArt;
    QString m_resolvedSource;
    QUrl m_resolvedArt;
    QString m_cacheDir;

    bool m_hasTrack = false;
    bool m_playing = false;
    QString m_title;
    QString m_artist;
    QString m_album;
    QUrl m_artUrl;
    qint64 m_length = 0;
    qint64 m_position = 0;
    bool m_canSeek = false;
    bool m_canGoNext = false;
    bool m_canGoPrevious = false;
    bool m_canControl = false;
    bool m_canShuffle = false;
    bool m_shuffle = false;
    QString m_identity;
    QString m_iconName;
    int m_songChangeToken = 0;
    bool m_ignoresBrowsers = true;
};
