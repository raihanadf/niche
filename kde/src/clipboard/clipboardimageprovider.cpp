#include "clipboardimageprovider.h"

#include <QMutexLocker>

void ClipboardImageStore::insert(const QString &id, const QImage &image)
{
    QMutexLocker lock(&m_mutex);
    m_images.insert(id, image);
}

void ClipboardImageStore::remove(const QString &id)
{
    QMutexLocker lock(&m_mutex);
    m_images.remove(id);
}

void ClipboardImageStore::clear()
{
    QMutexLocker lock(&m_mutex);
    m_images.clear();
    m_images.squeeze();
}

QImage ClipboardImageStore::image(const QString &id) const
{
    QMutexLocker lock(&m_mutex);
    return m_images.value(id);
}

ClipboardImageProvider::ClipboardImageProvider(std::shared_ptr<ClipboardImageStore> store)
    : QQuickImageProvider(QQmlImageProviderBase::Image)
    , m_store(std::move(store))
{
}

QImage ClipboardImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    QImage image = m_store->image(id);
    if (size) {
        *size = image.size();
    }
    if (image.isNull()) {
        return image;
    }
    // Only ever shrink; thumbnails are already small.
    const int width = requestedSize.width() > 0 ? requestedSize.width() : image.width();
    const int height = requestedSize.height() > 0 ? requestedSize.height() : image.height();
    if (width < image.width() || height < image.height()) {
        image = image.scaled(width, height, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    }
    return image;
}
