// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/iOS/ColdResumeBridge.h"

#include "Core/CellGrid.h"
#include "Core/Crypto/SHA256.h"
#include "Core/Protocol/Sync/SyncClientCore.h"
#include "Core/Screen/Addressing.h"
#include "Core/Screen/Scrollback.h"
#include "Core/Session/SealedResumeFile.h"
#include "Core/TerminalOperations.h"
#include "PAL/UnixFileDescriptor.h"
#include "Platform/Apple/SealedStoreDriver.h"

#include <algorithm>
#include <fcntl.h>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace {

namespace Sync = Ubiquitty::Protocol::Sync;

bool copyIdentity(UbiquittyIOSResumeIdentity identity, Ubiquitty::PAL::SealScope& scope, std::array<std::uint8_t, 32>& pin)
{
    if ((!identity.clientLow && !identity.clientHigh) || identity.digestLength != 32 || identity.pinLength != 32 || !identity.principalDigest || !identity.certificatePin)
        return false;
    std::array<std::uint8_t, 32> principal;
    std::copy_n(identity.principalDigest, 32, principal.begin());
    std::copy_n(identity.certificatePin, 32, pin.begin());
    scope = Ubiquitty::Session::resumeSealScope({ identity.hostLow, identity.hostHigh }, principal, { identity.clientLow, identity.clientHigh });
    return true;
}

/// One physical workspace owns this store. Swift owns protected target policy;
/// Core alone serializes pictures, receipts, secrets and input admission.
class IOSResumeStore final : public Sync::ResumeRecordStore {
public:
    IOSResumeStore(std::string path, UbiquittyIOSResumeHooks hooks, Sync::HistoryPersistence historyPersistence)
        : m_path(std::move(path))
        , m_hooks(hooks)
        , m_historyPersistence(historyPersistence)
    {
    }
    ~IOSResumeStore() override
    {
        if (m_ownsContext && m_hooks.release)
            m_hooks.release(m_hooks.context);
    }
    void takeContext() { m_ownsContext = true; }
    [[nodiscard]] Sync::HistoryPersistence historyPersistence() const override { return m_historyPersistence; }
    void setScope(const Ubiquitty::PAL::SealScope& scope, const std::array<std::uint8_t, 32>& pin)
    {
        const auto cap = Sync::measuredClientPolicy().maxCheckpointBytes;
        m_store.emplace(m_path, scope, pin, Ubiquitty::Apple::sealedStore(), Ubiquitty::Apple::restoreAuthorization(), cap, cap);
    }
    Sync::ResumeBindingOutcome bindWelcome(const Sync::Welcome& welcome, Sync::ID128 client, const std::array<std::uint8_t, 32>& pin) override
    {
        if (!m_hooks.mayUse(m_hooks.context))
            return Sync::ResumeBindingOutcome::Refused;
        if (std::ranges::all_of(pin, [](auto byte) { return byte == 0; }))
            return Sync::ResumeBindingOutcome::MemoryOnly;
        if (m_store && m_store->bindWelcome(welcome, client, pin) != Sync::ResumeBindingOutcome::Bound) {
            if (purge() != Sync::ResumePurgeOutcome::Purged)
                return Sync::ResumeBindingOutcome::Refused;
            m_store.reset();
        }
        if (!m_hooks.bind(m_hooks.context, welcome.hostInstanceID.low, welcome.hostInstanceID.high, welcome.principal.data(), welcome.principal.size(), pin.data(), pin.size()))
            return Sync::ResumeBindingOutcome::Refused;
        if (!m_store) {
            std::array<std::uint8_t, 32> principal;
            Ubiquitty::Crypto::sha256({ reinterpret_cast<const std::uint8_t*>(welcome.principal.data()), welcome.principal.size() }, principal);
            setScope(Ubiquitty::Session::resumeSealScope(welcome.hostInstanceID, principal, client), pin);
        }
        return m_store->bindWelcome(welcome, client, pin);
    }
    Sync::ResumeWriteOutcome write(const Sync::ResumeRecord& record) override
    {
        return m_store && m_hooks.mayUse(m_hooks.context) ? m_store->write(record) : Sync::ResumeWriteOutcome::Unchanged;
    }
    std::optional<Sync::ResumeRecord> read() override
    {
        if (!m_store || !m_hooks.mayUse(m_hooks.context))
            return std::nullopt;
        auto record = m_store->read();
        if (record) {
            for (const auto& pane : record->panes) {
                if (!pane.checkpoint.empty()) {
                    m_preview = pane.paneID;
                    break;
                }
            }
        }
        return record;
    }
    Sync::ResumePurgeOutcome purge() override
    {
        const auto outcome = m_store ? m_store->purge() : Sync::ResumePurgeOutcome::Purged;
        if (outcome == Sync::ResumePurgeOutcome::Refused)
            m_hooks.retirementRefused(m_hooks.context);
        return outcome;
    }
    [[nodiscard]] Sync::ID128 preview() const { return m_preview; }

private:
    std::string m_path;
    UbiquittyIOSResumeHooks m_hooks;
    Sync::HistoryPersistence m_historyPersistence;
    std::optional<Ubiquitty::Session::SealedResumeRecordStore> m_store;
    Sync::ID128 m_preview;
    bool m_ownsContext = false;
};

} // namespace

struct UbiquittyIOSResumeOwner {
    std::shared_ptr<IOSResumeStore> store;
    std::unique_ptr<Ubiquitty::Protocol::Sync::SyncClientCore> core;
};

extern "C" {

UbiquittyIOSResumeOwner* ubiquittyIOSResumeCreate(const char* path, UbiquittyIOSResumeIdentity identity, UbiquittyIOSResumeHooks hooks)
{
    Ubiquitty::PAL::SealScope scope;
    std::array<std::uint8_t, 32> pin;
    if (!path || path[0] != '/' || !hooks.mayUse || !hooks.bind || !hooks.retirementRefused || !copyIdentity(identity, scope, pin))
        return nullptr;
    auto owner = std::unique_ptr<UbiquittyIOSResumeOwner>(new (std::nothrow) UbiquittyIOSResumeOwner);
    if (!owner)
        return nullptr;
    owner->store = std::make_shared<IOSResumeStore>(path, hooks, identity.shouldPersistHistory ? Sync::HistoryPersistence::Enabled : Sync::HistoryPersistence::Disabled);
    if (identity.hostLow || identity.hostHigh)
        owner->store->setScope(scope, pin);
    owner->core.reset(new (std::nothrow) Ubiquitty::Protocol::Sync::SyncClientCore(nullptr, nullptr));
    if (!owner->core || !owner->core->prepareResumeStore(owner->store, { identity.clientLow, identity.clientHigh }, pin))
        return nullptr;
    owner->store->takeContext();
    return owner.release();
}

void ubiquittyIOSResumeDestroy(UbiquittyIOSResumeOwner* owner) { delete owner; }
uintptr_t ubiquittyIOSResumeCoreAddress(UbiquittyIOSResumeOwner* owner) { return owner ? reinterpret_cast<uintptr_t>(&owner->core) : 0; }
uint64_t ubiquittyIOSResumePreviewLow(const UbiquittyIOSResumeOwner* owner) { return owner ? owner->store->preview().low : 0; }
uint64_t ubiquittyIOSResumePreviewHigh(const UbiquittyIOSResumeOwner* owner) { return owner ? owner->store->preview().high : 0; }

bool ubiquittyIOSResumeRetire(const char* path, UbiquittyIOSResumeIdentity identity)
{
    Ubiquitty::PAL::SealScope scope;
    std::array<std::uint8_t, 32> pin;
    if (!path || path[0] != '/' || !copyIdentity(identity, scope, pin))
        return false;
    if (!identity.hostLow && !identity.hostHigh)
        return true;
    const auto cap = Sync::measuredClientPolicy().maxCheckpointBytes;
    Ubiquitty::Session::SealedResumeRecordStore store(path, scope, pin, Ubiquitty::Apple::sealedStore(), Ubiquitty::Apple::restoreAuthorization(), cap, cap);
    return store.purge() == Sync::ResumePurgeOutcome::Purged;
}

bool ubiquittyIOSResumeDirectoryDurable(const char* path)
{
    if (!path || path[0] != '/')
        return false;
    const std::string directory(path);
    const auto split = directory.find_last_of('/');
    if (split == 0 || split == directory.size() - 1)
        return false;
    Ubiquitty::PAL::UnixFileDescriptor parent(::open(directory.substr(0, split).c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    Ubiquitty::PAL::UnixFileDescriptor leaf(parent ? ::openat(parent.get(), directory.c_str() + split + 1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1);
    struct stat status {};
    return leaf && !::fstat(leaf.get(), &status) && status.st_uid == ::geteuid() && !(status.st_mode & 0077)
        && !::fcntl(leaf.get(), F_FULLFSYNC) && !::fcntl(parent.get(), F_FULLFSYNC);
}

#if defined(UBIQUITTY_IOS_UI_TESTS)
const char* ubiquittyIOSResumePopulateForTest(UbiquittyIOSResumeOwner* owner)
{
    if (!owner || !owner->core)
        return "no prepared owner";
    const std::array<std::uint8_t, 32> pin { 7 };
    const auto client = owner->core->clientInstance();
    Sync::Welcome welcome;
    welcome.hostInstanceID = { 90, 91 };
    welcome.principal = "cold-resume-smoke";
    if (owner->store->bindWelcome(welcome, client, pin) != Sync::ResumeBindingOutcome::Bound)
        return "welcome binding refused";
    auto terminal = std::make_unique<Ubiquitty::Terminal>();
    Ubiquitty::resize(*terminal, 4, 24);
    constexpr std::string_view text = "protected cold picture";
    auto cell = *Ubiquitty::Screen::visibleCell(terminal.get(), 0, 0, 0);
    for (std::size_t index = 0; index < text.size(); ++index) {
        cell.codePoint = static_cast<std::uint8_t>(text[index]);
        terminal->grid->setCell(Ubiquitty::Row { 0 }, Ubiquitty::Column { static_cast<int>(index) }, cell);
    }
    constexpr std::string_view historyText = "protected saved history";
    std::vector<Ubiquitty::Cell> historyRow;
    for (const auto character : historyText) {
        cell.codePoint = static_cast<std::uint8_t>(character);
        historyRow.push_back(cell);
    }
    for (int row = 0; row < 3; ++row)
        Ubiquitty::Screen::scrollbackAppend(terminal.get(), historyRow.data(), static_cast<int>(historyRow.size()), 0, 0, false, false);
    Sync::ScreenPublisher publisher;
    Sync::AttachmentBaseline baseline;
    Sync::ResumeRecordPane pane {};
    pane.paneID = { 7, 17 };
    if (!publisher.capture(*terminal) || !publisher.checkpoint(*terminal, 12, pane.checkpoint, baseline))
        return "fixture checkpoint refused";
    pane.checkpointDigest = Sync::digestOf(pane.checkpoint);
    auto inspected = std::make_unique<Ubiquitty::Terminal>();
    if (Sync::applyCheckpoint(*inspected, pane.checkpoint, pane.replica) != Sync::ApplyOutcome::Applied)
        return "fixture checkpoint did not apply";
    if (owner->store->historyPersistence() == Sync::HistoryPersistence::Enabled) {
        Sync::HistoryPublisher history;
        if (!history.capture(*terminal))
            return "fixture history refused";
        const auto address = history.address();
        std::vector<std::uint8_t> body;
        std::vector<Sync::DecodedLine> lines;
        if (history.writeBody(*terminal, { address.oldest, address.head }, Sync::HistoryOrder::Ascending, Sync::maxHistoryTransferBytes, body) != 3
            || !Sync::decodeHistoryBody(body, address.oldest, Sync::HistoryOrder::Ascending, Sync::historyBodyLimits, lines))
            return "fixture history refused";
        Sync::HistoryCache cache(welcome.hostInstanceID, pane.paneID, 100);
        if (cache.reset({ .newEpoch = address.epoch, .clearedThrough = address.oldest, .historyHead = address.head }) != Sync::HistoryPurgeOutcome::Purged
            || cache.insert(address.epoch, lines) != Sync::CacheInsert::Stored)
            return "fixture history refused";
        auto snapshot = cache.snapshot(1 << 20, 1 << 20);
        if (!snapshot)
            return "fixture history refused";
        pane.history = std::move(snapshot->bytes);
    }
    pane.effects = { .acknowledged = 3, .consumed = 5 };
    Sync::ResumeRecord record {};
    record.hostInstanceID = welcome.hostInstanceID;
    record.clientInstance = client;
    record.attachmentID = { 40, 41 };
    record.resumeSecret = { 50, 51 };
    record.certificatePin = pin;
    record.panes.push_back(std::move(pane));
    switch (owner->store->write(record)) {
    case Sync::ResumeWriteOutcome::Committed:
        return nullptr;
    case Sync::ResumeWriteOutcome::Unchanged:
        return "protected write unchanged";
    case Sync::ResumeWriteOutcome::DurabilityUnknown:
        return "protected write durability unknown";
    }
    return "protected write outcome unknown";
}

bool ubiquittyIOSResumeRestoredForTest(UbiquittyIOSResumeOwner* owner)
{
    if (!owner || !owner->core || !owner->core->heldAttachment())
        return false;
    auto destination = std::make_unique<Ubiquitty::Terminal>();
    return owner->core->heldAttachment()->resumeSecret == Sync::ID128 { 50, 51 }
    && owner->core->drawPreparedPane({ 7, 17 }, *destination) && destination->rows == 4 && destination->columns == 24
        && Ubiquitty::Screen::visibleCell(destination.get(), 0, 0, 0)->codePoint == 'p'
        && Ubiquitty::Screen::scrollbackCount(destination.get()) == (owner->store->historyPersistence() == Sync::HistoryPersistence::Enabled ? 3 : 0);
}
#endif

} // extern "C"
