// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "ColdResumeBridge.h"

// The C seam an iOS shell drives UbiquittyKit::Session through.
//
// Why a C seam rather than direct interop, since Swift reaches most of Core
// through -cxx-interoperability-mode=default and this file would otherwise be
// waste: the facade takes two abstract bases — UbiquittyKit::Session::Observer
// and Ubiquitty::Session::Dispatcher — and Swift cannot subclass a C++ class.
// Something has to derive from them, and on this frontend that something cannot
// be Objective-C++ either. So the derivation happens here, in C++, and the shell
// supplies function pointers.
//
// It follows Transport::DelegatedChannel::Driver's own shape rather than
// inventing one, because the carrier below has already answered this question
// the same way and for the same reason.
//
// Nothing in this file decides anything. The terminal model, the session
// lifecycle, the carrier contract and the visible text projection are all
// Core's; this is the adapter that lets a language with no C++ inheritance hold
// them. A rule that appears in this file is a rule in the wrong place.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// NOLINTBEGIN(modernize-use-using): `using` is C++, and this header is parsed
// as C. It is the interface of a clang module the Swift shell imports without
// interoperability flags, which is the whole reason the seam is C rather than
// the C++ it wraps — a `using` here would make the module unbuildable for its
// only consumer.

/// An owned session, opaque to the shell.
typedef struct UbiquittyIOSSessionOpaque UbiquittyIOSSession;

/// How a carrier finished.
///
/// Named rather than a boolean because only the carrier knows which happened
/// and neither can be inferred from the state before it: a connected carrier
/// reaches both. A `bool isFailure` at the call site also reads as its own
/// opposite half the time.
typedef enum {
    /// Stopped cleanly, or the peer closed.
    UbiquittyIOSCarrierOutcomeClosed = 0,
    /// A setup or I/O error tore it down.
    UbiquittyIOSCarrierOutcomeFailed = 1,
} UbiquittyIOSCarrierOutcome;

/// The shell's carrier, mirroring Transport::DelegatedChannel::Driver.
///
/// Every entry point receives `context`. `start` returning false is an
/// immediate local setup error after which no callback may fire; the rest are
/// optional and a null one is a no-op, on the same terms the C++ Driver states.
typedef struct {
    void* context;
    bool (*start)(void* context);
    void (*send)(void* context, const uint8_t* bytes, size_t byteCount);
    void (*stop)(void* context);
    void (*setWindowSize)(void* context, int columns, int rows);
    void (*release)(void* context);
    void (*suspendReading)(void* context);
    void (*resumeReading)(void* context);
    int64_t (*pendingOutboundBytes)(void* context);
    int64_t (*outboundCapacityBytes)(void* context);
    bool (*peerAuthenticationFailed)(void* context);
    /// Schedules a failure on the native callback thread without blocking.
    /// The reason is copied before return; no more outbound data is accepted.
    void (*fail)(void* context, const char* reason);
} UbiquittyIOSCarrierDriver;

/// What the session reports back to the shell.
///
/// Every callback arrives on the dispatcher's thread — the main queue — so a
/// shell may touch its UI directly from any of them without hopping again.
typedef struct {
    void* context;
    /// The grid changed; the surface should draw a frame.
    void (*onFrame)(void* context);
    /// The session set a window title. `utf8` is valid only during the call.
    void (*onTitle)(void* context, const char* utf8, size_t byteCount);
    void (*onBell)(void* context);
    /// The remote shell exited. No further callback follows.
    void (*onExit)(void* context);
    /// The link state moved. `detail` is valid only during the call and may be
    /// empty; `health` carries Ubiquitty::Session::Health's value.
    void (*onHealthChanged)(void* context, int32_t health, const char* detail, size_t byteCount);
    /// Releases `context`. Called exactly once, when the session is destroyed.
    void (*release)(void* context);
} UbiquittyIOSSessionObserver;

/// One control request without a terminal, pane, viewport, or focus report.
typedef struct UbiquittyIOSControlClientOpaque UbiquittyIOSControlClient;

/// The answer to a control request, delivered on the main queue.
///
/// Text is borrowed only during its callback. Destroying the client cancels
/// callbacks still queued. Each context is released exactly once.
typedef struct {
    void* context;
    void (*onAnswer)(void* context, const char* utf8, size_t byteCount);
    void (*onFailure)(void* context, const char* utf8, size_t byteCount);
    void (*release)(void* context);
} UbiquittyIOSControlObserver;

/// Creates a single-use control client over an already chosen carrier.
///
/// All control-client entry points, including inbound delivery, run on the
/// main queue. The carrier must copy inbound bytes before posting them and
/// look up its still-live client when the posted callback runs. No call may
/// use the handle after destruction. The driver's resize callback is ignored.
///
/// - Parameters:
///   - driver: The carrier hooks; ownership transfers even on failure.
///   - observer: The answer hooks; ownership transfers even on failure.
/// - Returns: The client, or null when `driver.start` is absent.
UbiquittyIOSControlClient* ubiquittyIOSControlClientCreate(UbiquittyIOSCarrierDriver driver, UbiquittyIOSControlObserver observer);

/// Starts one bounded JSON-RPC request. A second start is refused.
///
/// - Parameters:
///   - client: The client to start.
///   - request: The UTF-8 JSON-RPC request, copied before returning.
/// - Returns: Whether the request started.
bool ubiquittyIOSControlClientStart(UbiquittyIOSControlClient* client, const char* request);

/// Reports that the carrier is ready for the control handshake.
///
/// - Parameter client: The still-live control client, called on the main queue.
void ubiquittyIOSControlClientNotifyConnect(UbiquittyIOSControlClient* client);

/// Copies inbound bytes into the portable client's dispatcher.
///
/// - Parameters:
///   - client: The still-live control client, called on the main queue.
///   - bytes: The borrowed carrier bytes, copied before returning.
///   - byteCount: The number of readable bytes.
void ubiquittyIOSControlClientDeliver(UbiquittyIOSControlClient* client, const uint8_t* bytes, size_t byteCount);

/// Reports that the carrier closed, with its borrowed reason.
///
/// - Parameters:
///   - client: The still-live control client, called on the main queue.
///   - outcome: The carrier's terminal outcome.
///   - reason: The borrowed UTF-8 reason, copied before returning.
void ubiquittyIOSControlClientNotifyClose(UbiquittyIOSControlClient* client, UbiquittyIOSCarrierOutcome outcome, const char* reason);

/// Cancels the request and releases both contexts. Null is a no-op.
///
/// - Parameter client: The owned client to destroy on the main queue.
void ubiquittyIOSControlClientDestroy(UbiquittyIOSControlClient* client);

/// Copies Core's SSH exec command for reaching an existing daemon only.
///
/// - Parameters:
///   - buffer: Receives UTF-8 bytes without a terminator; null asks for size.
///   - capacity: Bytes available in `buffer`.
/// - Returns: The full command length, which may exceed `capacity`.
size_t ubiquittyIOSControlRemoteCommand(char* buffer, size_t capacity);

/// Creates a session whose carrier's bytes are the terminal stream itself.
///
/// This is UbiquittyKit::Session::createDirect: the origin for a carrier that
/// has already run a login shell on the far end, which is what an SSH channel
/// to an ordinary sshd gives a frontend that cannot fork a local one.
///
/// - Parameters:
///   - driver: The shell's carrier. Its context is owned by the session and
///     released through `driver.release` when the session is destroyed.
///   - originHost: "[user@]host" for status display. Copied.
///   - observer: The shell's hooks. Its context is owned on the same terms.
/// - Returns: The session, or null when `driver.start` is absent.
UbiquittyIOSSession* ubiquittyIOSSessionCreateDirect(UbiquittyIOSCarrierDriver driver,
    const char* originHost, UbiquittyIOSSessionObserver observer);

/// Starts the session at an initial geometry. Idempotent.
///
/// - Parameters:
///   - session: The session to start.
///   - columns: The initial grid width in cells.
///   - rows: The initial grid height in cells.
void ubiquittyIOSSessionStart(UbiquittyIOSSession* session, int columns, int rows);

/// Sends raw input bytes toward the shell.
///
/// Takes a pointer and a length rather than a C string: a key chord can carry
/// an embedded NUL — Ctrl-Space is one — and a NUL-terminated form would stop
/// at it.
///
/// - Parameters:
///   - session: The session to send toward.
///   - bytes: Borrowed for the duration of the call; copied before it returns.
///   - byteCount: How many bytes `bytes` holds.
void ubiquittyIOSSessionSendInput(UbiquittyIOSSession* session, const char* bytes, size_t byteCount);

/// Propagates a resize to the grid and to the carrier's own geometry.
///
/// - Parameters:
///   - session: The session to resize.
///   - columns: The new grid width in cells.
///   - rows: The new grid height in cells.
void ubiquittyIOSSessionSetSize(UbiquittyIOSSession* session, int columns, int rows);

/// Ends the session. Idempotent.
///
/// - Parameter session: The session to end.
void ubiquittyIOSSessionStop(UbiquittyIOSSession* session);

/// Stops the session, releases both contexts, and frees everything.
///
/// - Parameter session: The session to destroy. Null is a no-op.
void ubiquittyIOSSessionDestroy(UbiquittyIOSSession* session);

// ---- the carrier's inbound direction ------------------------------------
// Safe to call from the carrier's own I/O thread; each is dropped once the
// session has stopped, so a late call from a quiescing carrier is inert.

/// Reports that the carrier is up and ready for the first outbound bytes.
///
/// - Parameter session: The session whose carrier connected.
void ubiquittyIOSSessionNotifyConnect(UbiquittyIOSSession* session);

/// Delivers inbound bytes from the carrier.
///
/// - Parameters:
///   - session: The session to feed.
///   - bytes: Borrowed for the duration of the call.
///   - byteCount: How many bytes `bytes` holds.
void ubiquittyIOSSessionDeliver(UbiquittyIOSSession* session, const uint8_t* bytes, size_t byteCount);

/// Reports that the carrier finished, cleanly or otherwise.
///
/// - Parameters:
///   - session: The session whose carrier finished.
///   - outcome: Whether an error tore it down or it closed cleanly.
///   - reason: Short human note for status display. Borrowed; may be null.
void ubiquittyIOSSessionNotifyClose(UbiquittyIOSSession* session, UbiquittyIOSCarrierOutcome outcome, const char* reason);

// ---- reading the grid ----------------------------------------------------

/// Reports where the cursor sits, and whether the terminal is showing it.
///
/// The cell is the ACTIVE screen's, so it follows an application onto the
/// alternate screen rather than pointing into the primary one behind it.
///
/// - Parameters:
///   - session: The session to read.
///   - column: Receives the zero-based column. May be null.
///   - row: Receives the zero-based row. May be null.
/// - Returns: Whether the cursor is visible; a hidden cursor still has a cell.
bool ubiquittyIOSSessionCursor(UbiquittyIOSSession* session, int* column, int* row);

/// Returns the terminal's current column count.
///
/// - Parameter session: The session to read.
/// - Returns: The width in cells, or zero for a null session.
int ubiquittyIOSSessionColumns(UbiquittyIOSSession* session);

/// Returns the terminal's current row count.
///
/// - Parameter session: The session to read.
/// - Returns: The height in cells, or zero for a null session.
int ubiquittyIOSSessionRows(UbiquittyIOSSession* session);

// ---- host-key policy, which is Core's ------------------------------------
// The SSH package neither fingerprints nor compares, by design: there is one
// pinning policy across every frontend that stopped shelling out to `ssh`.
// These are that policy, reachable from Swift.

/// Writes the SHA-256 fingerprint of an SSH host key in OpenSSH's printed form.
///
/// - Parameters:
///   - keyBytes: The key in SSH wire encoding — the bytes a known_hosts line
///     base64s, so the digest matches `ssh-keygen -lf`.
///   - byteCount: How many bytes `keyBytes` holds.
///   - buffer: Receives the text; may be null to ask for the size alone.
///   - capacity: Bytes available in `buffer`.
/// - Returns: The full byte count, which may exceed `capacity`.
size_t ubiquittyIOSHostKeyFingerprint(const uint8_t* keyBytes, size_t byteCount, char* buffer, size_t capacity);

/// Judges a presented fingerprint against the pinned one.
///
/// - Parameters:
///   - pinnedFingerprint: What the store holds for the endpoint, or empty.
///   - presentedFingerprint: What the server offered this time.
/// - Returns: Ubiquitty::Transport::HostKeyVerdict — 0 unknown (no pin), 1
///   matched, 2 mismatched. A caller that receives 2 must refuse and must never
///   re-pin from it.
int32_t ubiquittyIOSVerifyHostKeyFingerprint(const char* pinnedFingerprint, const char* presentedFingerprint);

/// A channel request owned by the bootstrap provider until it answers exactly once.
typedef struct UbiquittyIOSQUICRequest UbiquittyIOSQUICRequest;
typedef struct UbiquittyIOSQUICFactory UbiquittyIOSQUICFactory;
typedef struct UbiquittyIOSSyncCarrier UbiquittyIOSSyncCarrier;

typedef enum UbiquittyIOSCarrierKind {
    UbiquittyIOSCarrierQUIC = 0,
    UbiquittyIOSCarrierSyncSSH = 1
} UbiquittyIOSCarrierKind;

/// Whether Core may retry a bootstrap that produced no carrier.
typedef enum UbiquittyIOSQUICFailureRecovery {
    UbiquittyIOSQUICFailureRetry = 0,
    UbiquittyIOSQUICFailureStop = 1,
    /// Authenticated SSH exec reached the host but offered no QUIC carrier.
    UbiquittyIOSQUICFailureUseStream = 2,
    /// The bootstrap was pinned to a daemon that is gone.
    UbiquittyIOSQUICFailureInstanceGone = 3
} UbiquittyIOSQUICFailureRecovery;

/// Supplies fresh bootstrap credentials for each physical connection.
///
/// All callbacks and completions run on the session thread. `release` cancels
/// and completes pending requests before releasing the provider's context.
typedef struct UbiquittyIOSQUICProvider {
    void* context;
    void (*request)(void* context, UbiquittyIOSQUICRequest* request);
    void (*release)(void* context);
} UbiquittyIOSQUICProvider;

/// Builds a factory that asks the provider for each connection's one-time token.
///
/// - Parameters:
///   - host: The host the carriers are for. It names the host and is never
///     dialled: each carrier dials the address its bootstrap's connection
///     reached.
///   - provider: Bootstrap callbacks; ownership transfers only on success.
/// - Returns: The factory, or null for an invalid host or missing callback.
UbiquittyIOSQUICFactory* ubiquittyIOSQUICFactoryCreate(const char* host, UbiquittyIOSQUICProvider provider);

/// Seeds a cold proof attempt from a protected descriptor. This does not
/// authenticate a connection: QUIC must verify this pin before any Welcome.
/// No bootstrap token or SSH command is accepted by this entry point.
///
/// - Parameters:
///   - factory: The unused physical carrier factory.
///   - numericAddress: The authenticated record's numeric reach address.
///   - port: The authenticated QUIC port, nonzero.
///   - certificateSHA256: The borrowed protected certificate pin bytes.
///   - certificateLength: The pin length, exactly 32.
/// - Returns: Whether the unused factory accepted the pinned proof reach.
bool ubiquittyIOSQUICFactorySeedResume(UbiquittyIOSQUICFactory* factory, const char* numericAddress, uint16_t port, const uint8_t* certificateSHA256, size_t certificateLength);

/// Pins the protected record's authenticated daemon basename before a cold
/// reconnect. This is not authority to change the record's host or session.
///
/// - Parameters:
///   - factory: The physical carrier factory.
///   - socketName: A nonempty safe daemon basename, not a path.
/// - Returns: Whether this exact owner was accepted; a different pin is refused.
bool ubiquittyIOSQUICFactoryPinDaemonOwner(UbiquittyIOSQUICFactory* factory, const char* socketName);

/// Copies the factory's pinned daemon basename without a null terminator.
/// Callers persist it only after the authenticated session is connected.
///
/// - Parameters:
///   - factory: The borrowed physical carrier factory; may be null.
///   - buffer: Receives the basename, or null to query the size.
///   - capacity: Available buffer bytes.
/// - Returns: The full basename byte count, or zero without a pinned owner.
size_t ubiquittyIOSQUICFactoryPinnedDaemonOwner(const UbiquittyIOSQUICFactory* factory, char* buffer, size_t capacity);

/// Writes the Core-built bootstrap command captured when the request was made.
///
/// The snapshot remains readable until the request is completed, even after
/// its factory is released or its owner changes. No null terminator is written.
/// - Parameters:
///   - request: The borrowed, uncompleted request; may be null.
///   - buffer: Receives the text; may be null to ask for the size alone.
///   - capacity: Bytes available in `buffer`.
/// - Returns: The full byte count, which may exceed `capacity`; zero for null.
size_t ubiquittyIOSQUICRequestBootstrapCommand(const UbiquittyIOSQUICRequest* request, char* buffer, size_t capacity);

/// The immutable requested carrier, not the last carrier the provider opened.
/// For SyncSSH the command getter returns the pinned passive exec command.
UbiquittyIOSCarrierKind ubiquittyIOSQUICRequestCarrierKind(const UbiquittyIOSQUICRequest* request);

/// True only for the factory's host-only errand door. Its native SSH channel
/// rejects any first HELLO that would bind or create a session or workspace.
bool ubiquittyIOSQUICRequestIsControlOnly(const UbiquittyIOSQUICRequest* request);

/// Reports whether a request's bootstrap names an exact daemon owner.
///
/// An unbound initial bootstrap may answer only a request without a pinned owner.
/// - Parameter request: The borrowed, uncompleted request; may be null.
/// - Returns: Whether the immutable request snapshot has a pinned owner.
bool ubiquittyIOSQUICRequestHasPinnedOwner(const UbiquittyIOSQUICRequest* request);

/// Reports whether the live factory still accepts the request's owner generation.
///
/// The provider checks before persisting a bootstrap result. Completion checks
/// again before updating resume reach or supplying a carrier.
/// - Parameter request: The borrowed, uncompleted request; may be null.
/// - Returns: Whether the request is current; false for null or a released factory.
bool ubiquittyIOSQUICRequestIsCurrent(const UbiquittyIOSQUICRequest* request);

/// Completes one bootstrap failure, retaining its cause for the session UI.
/// Copies at most 1024 UTF-8 bytes; stale requests cannot change factory state.
void ubiquittyIOSQUICRequestFail(UbiquittyIOSQUICRequest* request, UbiquittyIOSQUICFailureRecovery recovery, const char* detail, size_t detailLength);

/// Consumes a request and completes it with a pinned carrier, or failure.
///
/// A request may outlive its factory. Passing an empty token cancels it.
///
/// - Parameters:
///   - request: The request consumed exactly once by this call.
///   - port: The daemon's QUIC port.
///   - token: The decoded one-time token, or null for failure.
///   - tokenLength: The token's byte count.
///   - certificateSHA256: The decoded certificate pin.
///   - certificateLength: The pin's byte count.
///   - reachedAddress: The numeric address the SSH connection that ran the
///     bootstrap reached, as its socket reports it. The carrier dials it and
///     resolves nothing: the token and the pin are that machine's. Null, or
///     anything but a numeric address, fails the request.
void ubiquittyIOSQUICRequestComplete(UbiquittyIOSQUICRequest* request,
    uint16_t port, const uint8_t* token, size_t tokenLength,
    const uint8_t* certificateSHA256, size_t certificateLength,
    const char* reachedAddress);

/// Consumes a pinned SyncSSH request and native driver, including on failure.
/// All flow-control, capacity, and authentication hooks are required. `bind`
/// runs before Core starts the channel; the borrowed handle remains valid until
/// driver.stop quiesces callbacks and driver.release runs. This opens no PTY
/// and does not create a shell, workspace, or session.
void ubiquittyIOSQUICRequestCompleteSSH(UbiquittyIOSQUICRequest* request,
    UbiquittyIOSCarrierDriver driver, void (*bind)(void* context, UbiquittyIOSSyncCarrier* carrier));

/// The idle outbound frame capacity every Sync carrier must support.
size_t ubiquittyIOSSyncCarrierRequiredOutboundCapacity(void);

/// Inbound native calls; safe on the carrier's I/O thread until stop quiesces.
void ubiquittyIOSSyncCarrierNotifyConnect(UbiquittyIOSSyncCarrier* carrier);
void ubiquittyIOSSyncCarrierDeliver(UbiquittyIOSSyncCarrier* carrier, const uint8_t* bytes, size_t byteCount);
void ubiquittyIOSSyncCarrierNotifyClose(UbiquittyIOSSyncCarrier* carrier, UbiquittyIOSCarrierOutcome outcome, const char* reason);

/// Releases a factory. Only once the session using it has stopped.
void ubiquittyIOSQUICFactoryDestroy(UbiquittyIOSQUICFactory* factory);

/// The factory's address, for TerminalSurface.attachRemoteOverCarrier.
///
/// - Returns: The Ubiquitty::Session::ChannelFactory address, or zero.
uintptr_t ubiquittyIOSQUICFactoryAddress(UbiquittyIOSQUICFactory* factory);

/// Returns whether a host string is one this product will dial.
///
/// Core's floor, not a second one: the same characterSet that closes ARGV
/// injection for the frontends that still spawn `ssh`.
///
/// - Parameter host: The host name or address to judge.
/// - Returns: Whether it passes.
bool ubiquittyIOSValidateSSHHost(const char* host);

// NOLINTEND(modernize-use-using)

#ifdef __cplusplus
}
#endif
