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

// ---- known-answer test -------------------------------------------------------
//
// The same bytes docs/security/test-vectors.json holds under "moments" (master key 00 01 .. 1f, key id
// 0x01020304, note 7, offsets 512, 9216, 23296, 59999), made by docs/security/reference/note_format.py.
// The board seals them again and must get exactly these bytes, and open them again.
constexpr uint8_t kVectorFile[] = {
    0x43, 0x4e, 0x54, 0x31, 0x01, 0x00, 0x1c, 0x00, 0x04, 0x03, 0x02, 0x01,
    0x07, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x10, 0x00, 0x00, 0x51, 0x81, 0x0d, 0x62, 0x6b, 0x78, 0xa7, 0x92,
    0x88, 0x2c, 0x31, 0xcc, 0x2d, 0x98, 0x73, 0xae, 0xfe, 0x96, 0xf9, 0x5b,
    0x35, 0x52, 0xa3, 0xff, 0x78, 0xaa, 0x70, 0x8b, 0xdf, 0xa3, 0x40, 0x65,
    0x09, 0x09, 0x4b, 0x60,
};

inline bool selftest() {
    circuit_secure::Key key = {};
    for (size_t i = 0; i < sizeof(key.bytes); ++i) key.bytes[i] = static_cast<uint8_t>(i);
    key.id = 0x01020304;
    const uint32_t offsets[] = {512, 9216, 23296, 59999};
    uint8_t payload[4 + sizeof(offsets)];
    circuit_secure::detail::put_u32(payload, 4);
    for (size_t i = 0; i < 4; ++i) circuit_secure::detail::put_u32(payload + 4 + i * 4, offsets[i]);
    uint8_t file[kFileMax];
    const size_t length = circuit_secure::seal_buffer(key, 7 | kIdFlag, 0, 0, 0, circuit_secure::kChunkBytes, payload,
                                                      sizeof(payload), file, sizeof(file));
    if (length != sizeof(kVectorFile) || memcmp(file, kVectorFile, length) != 0) return false;
    uint8_t opened[kPayloadMax];
    size_t opened_length = 0;
    return circuit_secure::open_buffer(key, kVectorFile, sizeof(kVectorFile), opened, sizeof(opened), &opened_length) &&
           opened_length == sizeof(payload) && memcmp(opened, payload, sizeof(payload)) == 0;
}

}  // namespace circuit_moments
