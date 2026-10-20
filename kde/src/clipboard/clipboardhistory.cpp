#include "clipboardhistory.h"

#include "clipboardimageprovider.h"

#include <KGlobalAccel>
#include <KSystemClipboard>

#include <QAction>
#include <QFutureWatcher>
#include <QIcon>
#include <QImageReader>
#include <QKeySequence>
#include <QMimeData>
#include <QMimeDatabase>
#include <QRegularExpression>
#include <QTimer>
#include <QtConcurrent/QtConcurrentRun>

#include <algorithm>

namespace
{
const QString kindText = QStringLiteral("text");
const QString kindLink = QStringLiteral("link");
const QString kindColor = QStringLiteral("color");
const QString kindImage = QStringLiteral("image");
const QString kindFiles = QStringLiteral("files");

// Marks data this process put on the clipboard so pick() is not re-recorded.
const QString ownFormat = QStringLiteral("application/x-niche-kde-own");
// Set by KeePassXC, KWallet-aware apps, etc. on secrets (niche skips the
// macOS ConcealedType / TransientType equivalents).
const QString passwordHint = QStringLiteral("x-kde-passwordManagerHint");

constexpr qsizetype maxImageBytes = 8 << 20; // niche's per-image cap
constexpr qsizetype maxImageBudget = 32 << 20; // all full-size images together
constexpr int imageThumbSide = 128;
constexpr int previewLength = 300;
constexpr int labelLength = 200;
// Clipboard watchers replay the current selection right after they connect;
// like niche (which starts from the current changeCount) that is not a copy.
constexpr int armDelayMs = 1000;
// A clipboard manager may re-own what pick() wrote; treat an identical copy
// this soon after as our own.
constexpr qint64 ownEchoMs = 2000;
constexpr int pasteDelayMs = 150;

struct DecodedImage {
    QImage thumb;
    QSize size;
    size_t signature = 0;
    bool ok = false;
};

bool containsWhitespace(const QString &text)
{
    return std::any_of(text.cbegin(), text.cend(), [](QChar c) {
        return c.isSpace();
    });
}
}

ClipboardHistory::ClipboardHistory(QObject *parent)
    : QAbstractListModel(parent)
    , m_store(std::make_shared<ClipboardImageStore>())
{
    watchClipboard(true);
    QTimer::singleShot(armDelayMs, this, [this] {
        m_armed = true;
    });
    registerShortcut();
}

ClipboardHistory::~ClipboardHistory() = default;

int ClipboardHistory::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_items.size());
}

QVariant ClipboardHistory::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_items.size()) {
        return {};
    }
    const Item &item = m_items.at(index.row());
    switch (role) {
    case Qt::DisplayRole:
    case LabelRole:
        return item.label;
    case KindRole:
        return item.kind;
    case TextRole:
        return item.text;
    case PreviewRole:
        return item.preview;
    case ImageRole:
        return imageUrl(item);
    case ColorRole:
        return item.color.isValid() ? QVariant(item.color) : QVariant();
    case FileCountRole:
        return int(item.files.size());
    case DomainRole:
        return item.domain;
    case DateRole:
        return item.date;
    case ItemIdRole:
        return QString::number(item.id);
    default:
        return {};
    }
}

QHash<int, QByteArray> ClipboardHistory::roleNames() const
{
    return {
        {KindRole, "kind"},
        {TextRole, "text"},
        {PreviewRole, "preview"},
        {ImageRole, "image"},
        {ColorRole, "color"},
        {FileCountRole, "fileCount"},
        {LabelRole, "label"},
        {DomainRole, "domain"},
        {DateRole, "date"},
        {ItemIdRole, "itemId"},
    };
}

bool ClipboardHistory::enabled() const
{
    return m_enabled;
}

void ClipboardHistory::setEnabled(bool enabled)
{
    if (m_enabled == enabled) {
        return;
    }
    m_enabled = enabled;
    watchClipboard(enabled);
    if (!enabled) {
        clear();
    }
    Q_EMIT enabledChanged();
}

int ClipboardHistory::limit() const
{
    return m_limit;
}

void ClipboardHistory::setLimit(int limit)
{
    limit = std::clamp(limit, 3, maximumLimit);
    if (m_limit == limit) {
        return;
    }
    m_limit = limit;
    trimToLimit();
    Q_EMIT limitChanged();
}

int ClipboardHistory::maxLimit() const
{
    return maximumLimit;
}

bool ClipboardHistory::shortcutEnabled() const
{
    return m_shortcutEnabled;
}

void ClipboardHistory::setShortcutEnabled(bool enabled)
{
    if (m_shortcutEnabled == enabled) {
        return;
    }
    m_shortcutEnabled = enabled;
    if (enabled) {
        registerShortcut();
    } else {
        unregisterShortcut();
    }
    Q_EMIT shortcutEnabledChanged();
}

bool ClipboardHistory::pastesOnPick() const
{
    return m_pastesOnPick;
}

void ClipboardHistory::setPastesOnPick(bool pastes)
{
    if (m_pastesOnPick == pastes) {
        return;
    }
    m_pastesOnPick = pastes;
    Q_EMIT pastesOnPickChanged();
}

bool ClipboardHistory::canPaste() const
{
    return m_paster.isAvailable();
}

int ClipboardHistory::selection() const
{
    return m_selection;
}

void ClipboardHistory::setSelection(int selection)
{
    if (m_selection == selection) {
        return;
    }
    m_selection = selection;
    Q_EMIT selectionChanged();
}

int ClipboardHistory::count() const
{
    return int(m_items.size());
}

QAbstractItemModel *ClipboardHistory::model()
{
    return this;
}

QQuickImageProvider *ClipboardHistory::createImageProvider() const
{
    return new ClipboardImageProvider(m_store);
}

void ClipboardHistory::pick(int index)
{
    if (index < 0 || index >= m_items.size()) {
        return;
    }
    const Item item = m_items.at(index);
    writeToClipboard(item);
    if (index > 0) {
        beginMoveRows(QModelIndex(), index, index, QModelIndex(), 0);
        m_items.move(index, 0);
        endMoveRows();
    }
    if (m_pastesOnPick && m_paster.isAvailable()) {
        // Give the island time to drop keyboard focus so KWin hands it back to
        // the window the user was typing in.
        QTimer::singleShot(pasteDelayMs, this, [this] {
            m_paster.pasteShortcut();
        });
    }
}

QVariantMap ClipboardHistory::item(int index) const
{
    if (index < 0 || index >= m_items.size()) {
        return {};
    }
    const Item &item = m_items.at(index);
    return {
        {QStringLiteral("kind"), item.kind},
        {QStringLiteral("text"), item.text},
        {QStringLiteral("image"), imageUrl(item)},
        {QStringLiteral("color"), item.kind == kindColor ? item.color : QColor()},
    };
}

void ClipboardHistory::remove(int index)
{
    if (index < 0 || index >= m_items.size()) {
        return;
    }
    removeAt(index);
    updateCount();
}

void ClipboardHistory::clear()
{
    if (!m_items.isEmpty()) {
        beginResetModel();
        m_items.clear();
        m_items.squeeze();
        m_store->clear();
        endResetModel();
    }
    clampSelection();
    updateCount();
}

QColor ClipboardHistory::colorFrom(const QString &text) const
{
    return parseColor(text.trimmed());
}

QString ClipboardHistory::symbol(const QString &kind) const
{
    if (kind == kindLink) {
        return QStringLiteral("link");
    }
    if (kind == kindColor) {
        return QStringLiteral("color-management");
    }
    if (kind == kindImage) {
        return QStringLiteral("image-x-generic");
    }
    if (kind == kindFiles) {
        return QStringLiteral("document-single");
    }
    return QStringLiteral("format-justify-left");
}

QColor ClipboardHistory::parseColor(const QString &text)
{
    if ((text.size() != 7 && text.size() != 4) || !text.startsWith(QLatin1Char('#'))) {
        return {};
    }
    QString hex = text.mid(1);
    const bool allHex = std::all_of(hex.cbegin(), hex.cend(), [](QChar c) {
        return (c >= QLatin1Char('0') && c <= QLatin1Char('9')) || (c >= QLatin1Char('a') && c <= QLatin1Char('f'))
            || (c >= QLatin1Char('A') && c <= QLatin1Char('F'));
    });
    if (!allHex) {
        return {};
    }
    if (hex.size() == 3) {
        QString doubled;
        doubled.reserve(6);
        for (QChar c : std::as_const(hex)) {
            doubled.append(c).append(c);
        }
        hex = doubled;
    }
    bool ok = false;
    const uint value = hex.toUInt(&ok, 16);
    if (!ok) {
        return {};
    }
    return QColor::fromRgb((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff);
}

QString ClipboardHistory::firstLine(const QString &text)
{
    static const QRegularExpression newlines(QStringLiteral("[\\n\\r\\v\\f\\x{85}\\x{2028}\\x{2029}]"));
    const QStringList lines = text.split(newlines, Qt::SkipEmptyParts);
    const QString line = lines.isEmpty() ? text : lines.first();
    return line.size() > labelLength ? line.left(labelLength) : line;
}

QString ClipboardHistory::domainOf(const QString &text)
{
    const QString host = QUrl(text.trimmed()).host();
    if (host.isEmpty()) {
        return text;
    }
    return host.startsWith(QLatin1String("www.")) ? host.mid(4) : host;
}

QImage ClipboardHistory::thumbnail(const QImage &image, int side)
{
    QImage small = std::max(image.width(), image.height()) > side
        ? image.scaled(side, side, Qt::KeepAspectRatio, Qt::SmoothTransformation)
        : image;
    return small.convertToFormat(QImage::Format_ARGB32_Premultiplied);
}

QImage ClipboardHistory::fileIcon(const QUrl &file)
{
    const QMimeDatabase database;
    const QMimeType type = database.mimeTypeForFile(file.toLocalFile(), QMimeDatabase::MatchExtension);
    QIcon icon = QIcon::fromTheme(type.iconName());
    if (icon.isNull()) {
        icon = QIcon::fromTheme(type.genericIconName(), QIcon::fromTheme(QStringLiteral("unknown")));
    }
    // niche draws the Finder icon at 96 px; 48 logical at 2x.
    QImage image = icon.pixmap(QSize(48, 48), 2.0).toImage();
    image.setDevicePixelRatio(1.0);
    return image.isNull() ? image : image.convertToFormat(QImage::Format_ARGB32_Premultiplied);
}

void ClipboardHistory::watchClipboard(bool on)
{
    if (on == bool(m_clipboardConnection)) {
        return;
    }
    if (!on) {
        disconnect(m_clipboardConnection);
        m_clipboardConnection = {};
        return;
    }
    if (auto *clipboard = KSystemClipboard::instance()) {
        m_clipboardConnection = connect(clipboard, &KSystemClipboard::changed, this, &ClipboardHistory::clipboardChanged);
    }
}

void ClipboardHistory::clipboardChanged(QClipboard::Mode mode)
{
    if (mode != QClipboard::Clipboard || !m_enabled || !m_armed) {
        return;
    }
    const QMimeData *mime = KSystemClipboard::instance()->mimeData(QClipboard::Clipboard);
    if (!mime) {
        return;
    }
    const QStringList formats = mime->formats();
    if (formats.isEmpty() || formats.contains(ownFormat)) {
        return;
    }
    if (formats.contains(passwordHint) && mime->data(passwordHint).trimmed() == QByteArrayLiteral("secret")) {
        return;
    }

    if (mime->hasUrls()) {
        QList<QUrl> files;
        for (const QUrl &url : mime->urls()) {
            if (url.isLocalFile()) {
                files.append(url);
            }
        }
        if (!files.isEmpty()) {
            Item item = newItem(kindFiles);
            QStringList names;
            names.reserve(files.size());
            for (const QUrl &file : std::as_const(files)) {
                names.append(file.adjusted(QUrl::StripTrailingSlash).fileName());
            }
            item.text = names.join(QStringLiteral(", "));
            item.preview = item.text.left(previewLength);
            item.label = firstLine(item.text);
            item.files = files;
            item.signature = qHash(QUrl::toStringList(files).join(QLatin1Char('\n')));
            accept(std::move(item), fileIcon(files.first()));
            return;
        }
    }

    if (mime->hasText()) {
        const QString string = mime->text();
        const QString trimmed = string.trimmed();
        if (!trimmed.isEmpty()) {
            QString kind = kindText;
            const QUrl url(trimmed, QUrl::StrictMode);
            if (!containsWhitespace(trimmed) && url.isValid() && url.scheme().startsWith(QLatin1String("http")) && !url.host().isEmpty()) {
                kind = kindLink;
            } else if (parseColor(trimmed).isValid()) {
                kind = kindColor;
            }
            Item item = newItem(kind);
            item.text = string;
            item.preview = trimmed.left(previewLength);
            item.label = firstLine(string);
            if (kind == kindLink) {
                item.domain = domainOf(trimmed);
            } else if (kind == kindColor) {
                item.color = parseColor(trimmed);
            }
            item.signature = qHash(string);
            accept(std::move(item), QImage());
            return;
        }
    }

    readImage(mime, formats);
}

void ClipboardHistory::readImage(const QMimeData *mime, const QStringList &formats)
{
    QString format;
    if (formats.contains(QStringLiteral("image/png"))) {
        format = QStringLiteral("image/png");
    } else {
        const QList<QByteArray> supported = QImageReader::supportedMimeTypes();
        for (const QString &candidate : formats) {
            if (candidate.startsWith(QLatin1String("image/")) && supported.contains(candidate.toLatin1())) {
                format = candidate;
                break;
            }
        }
    }
    if (format.isEmpty()) {
        return;
    }
    const QByteArray data = mime->data(format);
    if (data.isEmpty() || data.size() > maxImageBytes) {
        return;
    }

    Item item = newItem(kindImage);
    item.imageFormat = format;
    item.imageData = data;

    // Decoding a screenshot takes long enough to stutter the island; do it off
    // the GUI thread and keep only the thumbnail plus the encoded bytes.
    auto *watcher = new QFutureWatcher<DecodedImage>(this);
    connect(watcher, &QFutureWatcherBase::finished, this, [this, watcher, item]() mutable {
        watcher->deleteLater();
        const DecodedImage decoded = watcher->result();
        if (!decoded.ok || !m_enabled) {
            return;
        }
        item.text = QStringLiteral("Image %1 × %2").arg(decoded.size.width()).arg(decoded.size.height());
        item.preview = item.text;
        item.label = item.text;
        item.signature = decoded.signature;
        accept(std::move(item), decoded.thumb);
    });
    watcher->setFuture(QtConcurrent::run([data] {
        DecodedImage decoded;
        const QImage image = QImage::fromData(data);
        if (image.isNull()) {
            return decoded;
        }
        decoded.size = image.size();
        decoded.thumb = thumbnail(image, imageThumbSide);
        decoded.signature = qHash(data);
        decoded.ok = true;
        return decoded;
    }));
}

ClipboardHistory::Item ClipboardHistory::newItem(const QString &kind)
{
    Item item;
    item.id = ++m_nextId;
    item.kind = kind;
    item.date = QDateTime::currentDateTime();
    return item;
}

void ClipboardHistory::accept(Item item, const QImage &thumb)
{
    if (isOwnEcho(item.signature)) {
        return;
    }
    if (!thumb.isNull()) {
        m_store->insert(QString::number(item.id), thumb);
        item.hasImage = true;
    }
    insert(item);
    emitCopied(item);
}

void ClipboardHistory::insert(const Item &item)
{
    for (int i = int(m_items.size()) - 1; i >= 0; --i) {
        if (m_items.at(i).signature == item.signature) {
            removeAt(i);
        }
    }
    // Newest first; an image decoded off-thread lands behind anything copied
    // while it was decoding.
    int position = 0;
    while (position < m_items.size() && m_items.at(position).id > item.id) {
        ++position;
    }
    beginInsertRows(QModelIndex(), position, position);
    m_items.insert(position, item);
    endInsertRows();
    trimToLimit();
    trimImageBudget(item.id);
    updateCount();
}

void ClipboardHistory::removeAt(int index)
{
    beginRemoveRows(QModelIndex(), index, index);
    const Item item = m_items.takeAt(index);
    if (item.hasImage) {
        m_store->remove(QString::number(item.id));
    }
    endRemoveRows();
    clampSelection();
}

void ClipboardHistory::trimToLimit()
{
    while (m_items.size() > m_limit) {
        removeAt(int(m_items.size()) - 1);
    }
    updateCount();
}

void ClipboardHistory::trimImageBudget(quint64 keepId)
{
    qsizetype total = 0;
    for (const Item &item : std::as_const(m_items)) {
        total += item.imageData.size();
    }
    for (int i = int(m_items.size()) - 1; i >= 0 && total > maxImageBudget; --i) {
        const Item &item = m_items.at(i);
        if (item.imageData.isEmpty() || item.id == keepId) {
            continue;
        }
        total -= item.imageData.size();
        removeAt(i);
    }
}

void ClipboardHistory::clampSelection()
{
    setSelection(std::clamp(m_selection, 0, std::max(int(m_items.size()) - 1, 0)));
}

void ClipboardHistory::updateCount()
{
    const int current = int(m_items.size());
    if (current != m_lastCount) {
        m_lastCount = current;
        Q_EMIT countChanged();
    }
}

void ClipboardHistory::writeToClipboard(const Item &item)
{
    auto *clipboard = KSystemClipboard::instance();
    if (!clipboard) {
        return;
    }
    auto *mime = new QMimeData;
    if (item.kind == kindFiles) {
        mime->setUrls(item.files);
    } else if (item.kind == kindImage) {
        mime->setData(item.imageFormat, item.imageData);
    } else {
        mime->setText(item.text);
    }
    mime->setData(ownFormat, QByteArrayLiteral("1"));
    m_ownSignature = item.signature;
    m_ownClock.start();
    clipboard->setMimeData(mime, QClipboard::Clipboard);
}

bool ClipboardHistory::isOwnEcho(size_t signature) const
{
    return m_ownClock.isValid() && m_ownClock.elapsed() < ownEchoMs && signature == m_ownSignature;
}

QUrl ClipboardHistory::imageUrl(const Item &item) const
{
    return item.hasImage ? QUrl(QStringLiteral("image://clipboard/") + QString::number(item.id)) : QUrl();
}

void ClipboardHistory::emitCopied(const Item &item)
{
    Q_EMIT copied(item.kind, item.text, imageUrl(item), item.kind == kindColor ? item.color : QColor());
}

void ClipboardHistory::registerShortcut()
{
    if (m_action) {
        return;
    }
    auto *action = new QAction(this);
    action->setObjectName(QStringLiteral("clipboard"));
    action->setText(tr("Show clipboard history"));
    action->setProperty("componentName", QStringLiteral("niche-kde"));
    action->setProperty("componentDisplayName", QStringLiteral("niche"));
    connect(action, &QAction::triggered, this, &ClipboardHistory::hotKey);
    KGlobalAccel::setGlobalShortcut(action, QKeySequence(Qt::CTRL | Qt::ALT | Qt::Key_V));
    m_action = action;
}

void ClipboardHistory::unregisterShortcut()
{
    if (!m_action) {
        return;
    }
    KGlobalAccel::self()->removeAllShortcuts(m_action);
    delete m_action;
}
