#pragma once

#include "fakeinputpaster.h"

#include <QAbstractListModel>
#include <QByteArray>
#include <QClipboard>
#include <QColor>
#include <QDateTime>
#include <QElapsedTimer>
#include <QImage>
#include <QList>
#include <QPointer>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>

#include <memory>

class QAction;
class QMimeData;
class QQuickImageProvider;
class ClipboardImageStore;

// niche's ClipboardHistory: remembers the last few copies (text, links, hex
// colors, images, files), shows them in the island, and puts a picked one back
// on the clipboard, optionally pasting it into the focused window.
//
// Watches the system clipboard through KSystemClipboard (ext-data-control on
// Wayland, so copies are seen while the island is unfocused). Images live in
// memory only; thumbnails are served as image://clipboard/<id>.
//
// The object is its own list model (roles below) and also exposes itself as
// `model` for QML.
class ClipboardHistory : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(int limit READ limit WRITE setLimit NOTIFY limitChanged)
    Q_PROPERTY(int maxLimit READ maxLimit CONSTANT)
    Q_PROPERTY(bool shortcutEnabled READ shortcutEnabled WRITE setShortcutEnabled NOTIFY shortcutEnabledChanged)
    Q_PROPERTY(bool pastesOnPick READ pastesOnPick WRITE setPastesOnPick NOTIFY pastesOnPickChanged)
    Q_PROPERTY(bool canPaste READ canPaste CONSTANT)
    Q_PROPERTY(int selection READ selection WRITE setSelection NOTIFY selectionChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(QAbstractItemModel *model READ model CONSTANT)

public:
    enum Role {
        KindRole = Qt::UserRole + 1, // "text" | "link" | "color" | "image" | "files"
        TextRole, // full text (file names joined with ", " for files, "Image W × H" for images)
        PreviewRole, // trimmed text, cut to a few hundred characters for tiles
        ImageRole, // image://clipboard/<id> (image thumbnail or file icon), empty otherwise
        ColorRole, // QColor for kind "color", undefined otherwise
        FileCountRole,
        LabelRole, // first non-empty line of text, for the caption
        DomainRole, // host without "www." for links
        DateRole, // when it was copied
        ItemIdRole, // stable id (survives moves)
    };
    Q_ENUM(Role)

    static constexpr int maximumLimit = 10;

    explicit ClipboardHistory(QObject *parent = nullptr);
    ~ClipboardHistory() override;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool enabled() const;
    void setEnabled(bool enabled);
    int limit() const;
    void setLimit(int limit);
    int maxLimit() const;
    bool shortcutEnabled() const;
    void setShortcutEnabled(bool enabled);
    bool pastesOnPick() const;
    void setPastesOnPick(bool pastes);
    bool canPaste() const;
    int selection() const;
    void setSelection(int selection);
    int count() const;
    QAbstractItemModel *model();

    // New provider sharing this history's thumbnails; the QML engine owns it
    // (register as "clipboard").
    QQuickImageProvider *createImageProvider() const;

    // Copies item `index` back to the clipboard and moves it to the front.
    // Pastes it (Ctrl+V via fake input, 150 ms later) when pastesOnPick and
    // canPaste. The island shows the "copied" moment itself (see item()).
    Q_INVOKABLE void pick(int index);
    Q_INVOKABLE void remove(int index);
    Q_INVOKABLE void clear();
    // {kind, text, image (QUrl), color (QColor, valid for kind "color")} of
    // item `index`; empty map when out of range.
    Q_INVOKABLE QVariantMap item(int index) const;

    // niche's ClipboardHistory.color(from:): "#rgb" / "#rrggbb" → color,
    // anything else → invalid color.
    Q_INVOKABLE QColor colorFrom(const QString &text) const;
    // niche's LabState.symbol(for:) mapped to Breeze icon names.
    Q_INVOKABLE QString symbol(const QString &kind) const;

Q_SIGNALS:
    void enabledChanged();
    void limitChanged();
    void shortcutEnabledChanged();
    void pastesOnPickChanged();
    void selectionChanged();
    void countChanged();
    // The global shortcut (Ctrl+Alt+V by default) was pressed.
    void hotKey();
    // A new copy landed in the history. `image` is the item's thumbnail url,
    // `color` is valid only for kind "color".
    void copied(const QString &kind, const QString &text, const QUrl &image, const QColor &color);

private:
    struct Item {
        quint64 id = 0;
        QString kind;
        QString text;
        QString preview;
        QString label;
        QString domain;
        QColor color;
        QList<QUrl> files;
        QByteArray imageData;
        QString imageFormat;
        bool hasImage = false;
        QDateTime date;
        size_t signature = 0;
    };

    static QColor parseColor(const QString &text);
    static QString firstLine(const QString &text);
    static QString domainOf(const QString &text);
    static QImage thumbnail(const QImage &image, int side);
    static QImage fileIcon(const QUrl &file);

    void watchClipboard(bool on);
    void clipboardChanged(QClipboard::Mode mode);
    void readImage(const QMimeData *mime, const QStringList &formats);
    Item newItem(const QString &kind);
    void accept(Item item, const QImage &thumb);
    void insert(const Item &item);
    void removeAt(int index);
    void trimToLimit();
    void trimImageBudget(quint64 keepId);
    void clampSelection();
    void updateCount();
    void writeToClipboard(const Item &item);
    bool isOwnEcho(size_t signature) const;
    QUrl imageUrl(const Item &item) const;
    void emitCopied(const Item &item);
    void registerShortcut();
    void unregisterShortcut();

    QList<Item> m_items;
    std::shared_ptr<ClipboardImageStore> m_store;
    FakeInputPaster m_paster;
    QPointer<QAction> m_action;
    QElapsedTimer m_ownClock;
    size_t m_ownSignature = 0;
    quint64 m_nextId = 0;
    int m_limit = maximumLimit;
    int m_selection = 0;
    int m_lastCount = 0;
    QMetaObject::Connection m_clipboardConnection;
    bool m_enabled = true;
    bool m_shortcutEnabled = true;
    bool m_pastesOnPick = true;
    bool m_armed = false;
};
