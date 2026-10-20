#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QQuickImageProvider>

#include <memory>

// In-memory thumbnails of clipboard items, keyed by item id. Shared between
// ClipboardHistory (writer, GUI thread) and the QML image provider (reader,
// possibly a loader thread); nothing touches the disk.
class ClipboardImageStore
{
public:
    void insert(const QString &id, const QImage &image);
    void remove(const QString &id);
    void clear();
    QImage image(const QString &id) const;

private:
    mutable QMutex m_mutex;
    QHash<QString, QImage> m_images;
};

// Serves `image://clipboard/<id>`.
class ClipboardImageProvider : public QQuickImageProvider
{
public:
    explicit ClipboardImageProvider(std::shared_ptr<ClipboardImageStore> store);

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    std::shared_ptr<ClipboardImageStore> m_store;
};
