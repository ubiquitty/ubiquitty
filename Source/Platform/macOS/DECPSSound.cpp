// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
// macOS realization of the PAL DECPS play-sound hook (PAL::playTones): one AudioQueue
// output fed by Core's ToneMixer, which owns the voices, the channels and the mix.
// Plain C AudioToolbox, so this stays a C++ TU. UBAppDelegate places it in the
// PAL::Context playTones slot via decpsToneSynth(). The parse and the note→frequency
// mapping live in portable Core (Prefixed.cpp); this TU only owns the device.
#include <AudioToolbox/AudioToolbox.h>

#include "Core/VT/DECPSSynth.h"
#include "PAL/PAL.h"

#include <atomic>
#include <cmath>
#include <mutex>

namespace {

using Ubiquitty::VT::ToneMixer;

constexpr int bufferCount = 3;
constexpr uint32_t framesPerBuffer = 512; // 12 ms a buffer: the latency a request waits for the mix
constexpr int channelsPerFrame = 2; // the mix is stereo; a request's pan places it
// The output keeps running through a second of silence before it stops. A
// stop is asynchronous and the queue cannot start again until it has
// drained, so stopping at the first idle buffer made every short tick pay a
// restart and the Teletype's clatter fall behind its letters.
constexpr uint32_t idleFramesBeforeStop = 44100;

// The one output for the process: the mixer, the queue that drains it, and
// the queue's state. The parser thread enqueues requests and the queue's own
// thread pulls the mix, so the mixer sits behind a mutex; the queue is started
// when a request finds it stopped and stops itself once the mixer is idle.
struct Output {
    std::mutex mutex;
    ToneMixer mixer;
    AudioQueueRef queue = nullptr;
    bool isRunning = false;
    bool isStopping = false;
    uint32_t idleFrames = 0; // silent frames mixed since the last sound
    // The user's two sound settings, pushed in from the config rather than read
    // here: the queue's thread reads the gain every buffer, and the parser
    // thread reads the switch on every request, so neither may touch the
    // preferences store a reload is rewriting.
    std::atomic<Ubiquitty::PAL::SoundOutput> output { Ubiquitty::PAL::SoundOutput::Audible };
    std::atomic<float> gain { 1.0f };
};

Output& output()
{
    static Output* const instance = new Output;
    return *instance;
}

void decpsCallback(void* userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    Output& out = *static_cast<Output*>(userData);
    const uint32_t frames = buffer->mAudioDataBytesCapacity / (sizeof(int16_t) * channelsPerFrame);
    bool shouldStop = false;
    int16_t* samples = static_cast<int16_t*>(buffer->mAudioData);
    {
        std::lock_guard<std::mutex> lock(out.mutex);
        const bool isActive = out.mixer.mix(samples, frames);
        out.idleFrames = isActive ? 0 : out.idleFrames + frames;
        shouldStop = out.idleFrames >= idleFramesBeforeStop && !out.isStopping;
        if (shouldStop)
            out.isStopping = true;
    }
    // The user's volume rides on the mix rather than on each request, so it
    // applies to what is already sounding the moment they move the slider.
    const float gain = out.gain.load(std::memory_order_relaxed);
    if (gain < 0.999f)
        for (uint32_t i = 0; i < frames * channelsPerFrame; ++i)
            samples[i] = static_cast<int16_t>(std::lround(samples[i] * gain));
    buffer->mAudioDataByteSize = frames * sizeof(int16_t) * channelsPerFrame;
    AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
    // Async stop lets the buffers already enqueued play out; the IsRunning
    // listener then records the stop.
    if (shouldStop)
        AudioQueueStop(queue, false);
}

// Primes the buffers and starts the queue. Called without the mutex held: the
// priming fills go through the callback, which takes it.
void start(Output& out)
{
    for (int i = 0; i < bufferCount; ++i) {
        AudioQueueBufferRef buffer = nullptr;
        if (AudioQueueAllocateBuffer(out.queue, framesPerBuffer * sizeof(int16_t) * channelsPerFrame, &buffer) != noErr)
            continue;
        decpsCallback(&out, out.queue, buffer);
    }
    AudioQueueStart(out.queue, nullptr);
}

void decpsRunningChanged(void* userData, AudioQueueRef queue, AudioQueuePropertyID)
{
    uint32_t running = 0, size = sizeof(running);
    if (AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &running, &size) != noErr)
        return;
    Output& out = *static_cast<Output*>(userData);
    bool shouldRestart = false;
    {
        std::lock_guard<std::mutex> lock(out.mutex);
        out.isRunning = running != 0;
        if (running == 0) {
            out.isStopping = false;
            out.idleFrames = 0;
            // A request that arrived while the queue was stopping is waiting.
            if (!out.mixer.isIdle()) {
                out.isRunning = true;
                shouldRestart = true;
            }
        }
    }
    if (shouldRestart)
        start(out);
}

bool openQueue(Output& out)
{
    if (out.queue)
        return true;
    AudioStreamBasicDescription format = {};
    format.mSampleRate = Ubiquitty::VT::toneSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mChannelsPerFrame = channelsPerFrame;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = sizeof(int16_t) * channelsPerFrame;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    if (AudioQueueNewOutput(&format, decpsCallback, &out, nullptr, nullptr, 0, &out.queue) != noErr) {
        out.queue = nullptr;
        return false;
    }
    AudioQueueAddPropertyListener(out.queue, kAudioQueueProperty_IsRunning, decpsRunningChanged, &out);
    return true;
}

void decpsPlayTones(const Ubiquitty::PAL::PlayTonesRequest& request)
{
    Output& out = output();
    // Sound off means no sound, including whatever is already playing: a person
    // who turns it off wants the room quiet now, not after the current bar. A
    // stop request still goes through, so a channel cannot be left ringing.
    if (out.output.load(std::memory_order_relaxed) == Ubiquitty::PAL::SoundOutput::Silenced) {
        std::lock_guard<std::mutex> lock(out.mutex);
        Ubiquitty::PAL::PlayTonesRequest silence;
        silence.channel = 0;
        silence.volume = 0;
        out.mixer.enqueue(silence);
        return;
    }
    bool shouldStart = false;
    {
        std::lock_guard<std::mutex> lock(out.mutex);
        out.mixer.enqueue(request);
        out.idleFrames = 0;
        if (out.mixer.isIdle())
            return;
        if (!openQueue(out))
            return;
        if (!out.isRunning && !out.isStopping) {
            out.isRunning = true;
            shouldStart = true;
        }
    }
    if (shouldStart)
        start(out);
}

} // namespace

namespace {

Ubiquitty::PAL::SoundStatus decpsSoundStatusNow()
{
    const Output& out = output();
    Ubiquitty::PAL::SoundStatus status;
    status.hasSynth = true;
    const float gain = out.gain.load(std::memory_order_relaxed);
    status.isAudible = out.output.load(std::memory_order_relaxed) == Ubiquitty::PAL::SoundOutput::Audible && gain > 0.0f;
    status.volumePercent = static_cast<uint8_t>(std::lround(std::clamp(gain, 0.0f, 1.0f) * 100.0f));
    return status;
}

} // namespace

namespace Ubiquitty::PAL {

// The AudioToolbox output, for the app to place in the PAL::Context playTones
// slot at startup (frontend-internal; not part of the PAL.h contract).
PlayTonesCallback decpsToneSynth() { return &decpsPlayTones; }

// The status reporter for the same slot's neighbour, so a program that asks
// whether anyone will hear its chime gets this frontend's real answer.
SoundStatusCallback decpsSoundStatus() { return &decpsSoundStatusNow; }

// Pushes the user's [sound] settings in, at launch and on every config reload.
// The synth holds them in atomics rather than reading the preferences store,
// which the reload is rewriting under it.
void decpsApplySoundPreferences(SoundOutput setting, double volume)
{
    Output& out = output();
    out.output.store(setting, std::memory_order_relaxed);
    out.gain.store(static_cast<float>(std::clamp(volume, 0.0, 1.0)), std::memory_order_relaxed);
}

}
// namespace Ubiquitty::PAL
