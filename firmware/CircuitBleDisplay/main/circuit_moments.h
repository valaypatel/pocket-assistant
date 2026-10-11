#pragma once
// Moments: bookmarks a person adds during a recording with the lower key. Each one-minute part
// that has any gets a small sealed file next to it, /sdcard/NOTES/N0000141.MOM, holding the
// moments' offsets in milliseconds from the start of that part.
//
// The file is an ordinary CNT1 file (circuit_crypto.h), sealed with the notes key, so the card
// still only holds ciphertext. Two things set it apart from audio:
//   - its header carries the note number OR 0x80000000 (kIdFlag). The nonce is the note number
//     plus the chunk number, so without the flag the first chunk would reuse the audio's nonce.
//     Note numbers stay far below 2^31, so the flagged numbers can never meet a real note.
//   - rate, channels and bits are 0, so it can never be taken for audio.
// Payload (little-endian): u32 count, then count x u32 offset in ms.

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "circuit_crypto.h"
#include "circuit_notes.h"

namespace circuit_moments {

constexpr uint32_t kIdFlag = 0x80000000u;
constexpr size_t kMaxPerPart = 120;
constexpr size_t kPayloadMax = 4 + kMaxPerPart * 4;
constexpr size_t kFileMax = circuit_secure::kHeaderBytes + kPayloadMax + circuit_secure::kTagBytes;

inline void path_for(uint32_t note_id, char *out, size_t size) { circuit_notes::path_for(note_id, "MOM", out, size); }

// Seals and writes the file. Offsets must be in recording order. False if it could not be written.
inline bool save(uint32_t note_id, const circuit_secure::Key &key, const uint32_t *ms, size_t count) {
    if (count == 0 || count > kMaxPerPart || key.id == 0) return false;
    uint8_t payload[kPayloadMax];
    circuit_secure::detail::put_u32(payload, static_cast<uint32_t>(count));
    for (size_t i = 0; i < count; ++i) circuit_secure::detail::put_u32(payload + 4 + i * 4, ms[i]);
    uint8_t file[kFileMax];
    const size_t length = circuit_secure::seal_buffer(key, note_id | kIdFlag, 0, 0, 0, circuit_secure::kChunkBytes,
                                                      payload, 4 + count * 4, file, sizeof(file));
    if (length == 0) return false;
    char path[48];
    path_for(note_id, path, sizeof(path));
    FILE *out = fopen(path, "wb");
    if (out == nullptr) return false;
    const bool ok = fwrite(file, 1, length, out) == length;
    return fclose(out) == 0 && ok;
}

// Reads the offsets back. Returns how many (0 if there is no file, or it does not check out).
inline size_t load(uint32_t note_id, const circuit_secure::Key &key, uint32_t *ms, size_t capacity) {
    char path[48];
    path_for(note_id, path, sizeof(path));
    FILE *in = fopen(path, "rb");
    if (in == nullptr) return 0;
    uint8_t file[kFileMax];
    const size_t length = fread(file, 1, sizeof(file), in);
    fclose(in);
    // The header must name this note: a moments file moved to another note must not open.
    if (length < circuit_secure::kHeaderBytes || circuit_secure::detail::get_u32(file + 12) != (note_id | kIdFlag)) return 0;
    uint8_t payload[kPayloadMax];
    size_t payload_length = 0;
    if (!circuit_secure::open_buffer(key, file, length, payload, sizeof(payload), &payload_length) || payload_length < 4) return 0;
    const size_t count = circuit_secure::detail::get_u32(payload);
    if (count == 0 || count > kMaxPerPart || payload_length != 4 + count * 4) return 0;
    const size_t take = count < capacity ? count : capacity;
    for (size_t i = 0; i < take; ++i) ms[i] = circuit_secure::detail::get_u32(payload + 4 + i * 4);
    return take;
}

}  // namespace circuit_moments
