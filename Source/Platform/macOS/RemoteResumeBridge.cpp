// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/macOS/RemoteResumeBridge.h"

#include "Core/Crypto/SHA256.h"
#include "Core/Protocol/Sync/SyncClientCore.h"
#include "Core/Session/SealedResumeFile.h"
#include "Platform/Apple/SealedStoreDriver.h"

#include <algorithm>
#include <array>
#include <memory>
#include <new>
#include <optional>
#include <string>

namespace {

namespace Sync = Ubiquitty::Protocol::Sync;

/// Reads a descriptor's scope; a window with no peer yet has a zero host.
bool copyIdentity(UbiquittyMacResumeIdentity identity, Ubiquitty::PAL::SealScope& scope, std::array<std::uint8_t, 32>& pin)
{
    if ((!identity.clientLow && !identity.clientHigh) || identity.digestLength != 32 || identity.pinLength != 32 || !identity.principalDigest || !identity.certificatePin)
        return false;
    std::array<std::uint8_t, 32> principal;
    std::copy_n(identity.principalDigest, 32, principal.begin());
    std::copy_n(identity.certificatePin, 32, pin.begin());
    scope = Ubiquitty::Session::resumeSealScope({ identity.hostLow, identity.hostHigh }, principal, { identity.clientLow, identity.clientHigh });
    return true;
}

/// The window's store: the Apple sealed store, scoped once a Welcome names
/// the peer. The descriptor's bind hook records that peer before the store
/// commits anything for it, so a relaunch can scope the store before I/O.
class MacResumeStore final : public Sync::ResumeRecordStore {
public:
    MacResumeStore(std::string path, UbiquittyMacResumeHooks hooks)
        : m_path(std::move(path))
        , m_hooks(hooks)
    {
    }
    ~MacResumeStore() override
    {
        if (m_ownsContext && m_hooks.release)
            m_hooks.release(m_hooks.context);
    }
    MacResumeStore(const MacResumeStore&) = delete;
    MacResumeStore& operator=(const MacResumeStore&) = delete;

    void takeContext() { m_ownsContext = true; }

    void setScope(const Ubiquitty::PAL::SealScope& scope, const std::array<std::uint8_t, 32>& pin)
    {
        const auto cap = Sync::measuredClientPolicy().maxCheckpointBytes;
        m_store.emplace(m_path, scope, pin, Ubiquitty::Apple::sealedStore(), Ubiquitty::Apple::restoreAuthorization(), cap, cap);
    }

    Sync::ResumeBindingOutcome bindWelcome(const Sync::Welcome& welcome, Sync::ID128 client, const std::array<std::uint8_t, 32>& pin) override
    {
        // A record is kept only for a carrier that pinned its peer.
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
        return m_store ? m_store->write(record) : Sync::ResumeWriteOutcome::Unchanged;
    }

    std::optional<Sync::ResumeRecord> read() override
    {
        if (!m_store)
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

    Sync::ResumePurgeOutcome purge() override { return m_store ? m_store->purge() : Sync::ResumePurgeOutcome::Purged; }

    [[nodiscard]] Sync::ID128 preview() const { return m_preview; }

private:
    std::string m_path;
    UbiquittyMacResumeHooks m_hooks;
    std::optional<Ubiquitty::Session::SealedResumeRecordStore> m_store;
    Sync::ID128 m_preview;
    bool m_ownsContext = false;
};

} // namespace

struct UbiquittyMacResumeOwner {
    std::shared_ptr<MacResumeStore> store;
    std::unique_ptr<Ubiquitty::Protocol::Sync::SyncClientCore> core;
};

extern "C" {

UbiquittyMacResumeOwner* ubiquittyMacResumeCreate(const char* path, UbiquittyMacResumeIdentity identity, UbiquittyMacResumeHooks hooks)
{
    Ubiquitty::PAL::SealScope scope;
    std::array<std::uint8_t, 32> pin;
    if (!path || path[0] != '/' || !hooks.bind || !copyIdentity(identity, scope, pin))
        return nullptr;
    auto owner = std::unique_ptr<UbiquittyMacResumeOwner>(new (std::nothrow) UbiquittyMacResumeOwner);
    if (!owner)
        return nullptr;
    owner->store = std::make_shared<MacResumeStore>(path, hooks);
    if (identity.hostLow || identity.hostHigh)
        owner->store->setScope(scope, pin);
    owner->core.reset(new (std::nothrow) Ubiquitty::Protocol::Sync::SyncClientCore(nullptr, nullptr));
    if (!owner->core || !owner->core->prepareResumeStore(owner->store, { identity.clientLow, identity.clientHigh }, pin))
        return nullptr;
    owner->store->takeContext();
    return owner.release();
}

void ubiquittyMacResumeDestroy(UbiquittyMacResumeOwner* owner) { delete owner; }

uintptr_t ubiquittyMacResumeCoreAddress(UbiquittyMacResumeOwner* owner) { return owner ? reinterpret_cast<uintptr_t>(&owner->core) : 0; }

uint64_t ubiquittyMacResumePreviewLow(const UbiquittyMacResumeOwner* owner) { return owner ? owner->store->preview().low : 0; }

uint64_t ubiquittyMacResumePreviewHigh(const UbiquittyMacResumeOwner* owner) { return owner ? owner->store->preview().high : 0; }

bool ubiquittyMacResumeRetire(const char* path, UbiquittyMacResumeIdentity identity)
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

} // extern "C"
