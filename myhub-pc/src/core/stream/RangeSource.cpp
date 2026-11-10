#include "RangeSource.h"

namespace myhub {

RangeSource::RangeSource(QObject *parent)
    : QObject(parent)
{}

RangeSource::~RangeSource() = default;

void RangeSource::cancel()
{
    setCanceled(true);
}

void RangeSource::setCanceled(bool canceled)
{
    m_canceled = canceled;
}

} // namespace myhub
