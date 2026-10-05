#pragma once

// Encrypted notes (format "CNT1"; see docs/security/README.md).
//
// A note is stored as a 28-byte header followed by 4 KB chunks, each sealed with
// AES-256-GCM under the board's one notes key. The nonce is the note number plus
// the chunk number, and note numbers are never reused, so a nonce is never used
// twice. The header and the chunk's position are authenticated, so chunks cannot
// be reordered or moved between notes. What the SD card holds, and what the sync
// sends, is ciphertext: only the board and the phone it is paired with have the key.
//
// Kept free of the rest of the firmware so the same bytes can be checked at boot
// against the vector the Android app is tested with.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>

#include "esp_random.h"
#include "mbedtls/gcm.h"
#include "nvs.h"

namespace circuit_secure {

constexpr size_t kKeyBytes = 32;
constexpr size_t kHeaderBytes = 28;
constexpr size_t kTagBytes = 16;
constexpr uint32_t kChunkBytes = 4096;
constexpr uint8_t kVersion = 1;

struct Key {
    uint8_t bytes[kKeyBytes];
    uint32_t id;  // 0 means "no key"
};

// ---- the notes keys, kept in the board's flash -------------------------------
//
// Keys are only ever added. Each is stored under its own id, and one is "active"
// (used for new notes). Nothing here deletes or replaces a key, so a note stays
// openable by the board for as long as it exists, whatever happens to pairing. A
// newer key is simply used for newer notes; a phone paired later is given only the
// active key, so it cannot read notes sealed with an older one.

constexpr char kNamespace[] = "circuit_sec";

inline void key_name(uint32_t id, char out[16]) { snprintf(out, 16, "k%08lx", static_cast<unsigned long>(id)); }

inline bool load_key_by_id(uint32_t id, Key *key) {
    memset(key, 0, sizeof(*key));
    nvs_handle_t handle;
    if (id == 0 || nvs_open(kNamespace, NVS_READONLY, &handle) != ESP_OK) return false;
    char name[16];
    key_name(id, name);
    size_t size = kKeyBytes;
    const bool ok = nvs_get_blob(handle, name, key->bytes, &size) == ESP_OK && size == kKeyBytes;
    nvs_close(handle);
    if (ok) key->id = id;
    else memset(key, 0, sizeof(*key));
    return ok;
}

// The key used for new notes.
inline bool load_key(Key *key) {
    nvs_handle_t handle;
    uint32_t id = 0;
    if (nvs_open(kNamespace, NVS_READONLY, &handle) != ESP_OK) {
        memset(key, 0, sizeof(*key));
        return false;
    }
    const bool have = nvs_get_u32(handle, "active", &id) == ESP_OK;
    nvs_close(handle);
    return have && load_key_by_id(id, key);
}

// Makes a new key and makes it the active one. Existing keys are left alone.
inline bool create_key(Key *key) {
    nvs_handle_t handle;
    if (nvs_open(kNamespace, NVS_READWRITE, &handle) != ESP_OK) return false;
    esp_fill_random(key->bytes, kKeyBytes);
    char name[16];
    size_t size = 0;
    do {
        key->id = esp_random();
        key_name(key->id, name);
    } while (key->id == 0 || nvs_get_blob(handle, name, nullptr, &size) == ESP_OK);  // never reuse an id
    const bool ok = nvs_set_blob(handle, name, key->bytes, kKeyBytes) == ESP_OK && nvs_commit(handle) == ESP_OK &&
                    nvs_set_u32(handle, "active", key->id) == ESP_OK && nvs_commit(handle) == ESP_OK;
    nvs_close(handle);
    if (!ok) memset(key, 0, sizeof(*key));
    return ok;
}

// ---- format -----------------------------------------------------------------

namespace detail {

inline void put_u32(uint8_t *out, uint32_t value) {
    for (int i = 0; i < 4; ++i) out[i] = static_cast<uint8_t>(value >> (8 * i));
}
inline void put_u64(uint8_t *out, uint64_t value) {
    for (int i = 0; i < 8; ++i) out[i] = static_cast<uint8_t>(value >> (8 * i));
}
inline uint32_t get_u32(const uint8_t *in) {
    return in[0] | (in[1] << 8) | (in[2] << 16) | (static_cast<uint32_t>(in[3]) << 24);
}
inline uint16_t get_u16(const uint8_t *in) { return static_cast<uint16_t>(in[0] | (in[1] << 8)); }

// header: "CNT1", version, 0, header length (u16), key id, note id, rate, channels (u16),
// bits (u16), chunk size (all little-endian)
inline void make_header(uint8_t out[kHeaderBytes], uint32_t key_id, uint32_t note_id, uint32_t rate, uint16_t channels,
                        uint16_t bits, uint32_t chunk_bytes) {
    memcpy(out, "CNT1", 4);
    out[4] = kVersion;
    out[5] = 0;
    out[6] = kHeaderBytes & 0xff;
    out[7] = 0;
    put_u32(out + 8, key_id);
    put_u32(out + 12, note_id);
    put_u32(out + 16, rate);
    out[20] = channels & 0xff;
    out[21] = channels >> 8;
    out[22] = bits & 0xff;
    out[23] = bits >> 8;
    put_u32(out + 24, chunk_bytes);
}

// One note's cipher state. AAD = header || chunk index (u64 LE); nonce = note id (u32 LE) || chunk index (u64 LE).
struct Cipher {
    uint8_t header[kHeaderBytes];
    uint64_t index = 0;
    mbedtls_gcm_context gcm;
    bool ready = false;

    Cipher() { mbedtls_gcm_init(&gcm); }
    ~Cipher() { mbedtls_gcm_free(&gcm); }

    bool start(const Key &key, const uint8_t *hdr) {
        memcpy(header, hdr, kHeaderBytes);
        index = 0;
        ready = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key.bytes, 256) == 0;
        return ready;
    }

    void context(uint8_t aad[kHeaderBytes + 8], uint8_t nonce[12]) const {
        memcpy(aad, header, kHeaderBytes);
        put_u64(aad + kHeaderBytes, index);
        put_u32(nonce, get_u32(header + 12));
        put_u64(nonce + 4, index);
    }

    // out holds len + kTagBytes bytes.
    bool seal(const uint8_t *in, size_t len, uint8_t *out) {
        uint8_t aad[kHeaderBytes + 8], nonce[12];
        context(aad, nonce);
        const bool ok = ready && mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, len, nonce, 12, aad, sizeof(aad),
                                                           in, out, kTagBytes, out + len) == 0;
        if (ok) ++index;
        return ok;
    }

    // in holds len ciphertext bytes then the tag; out gets len bytes.
    bool open(const uint8_t *in, size_t len, uint8_t *out) {
        uint8_t aad[kHeaderBytes + 8], nonce[12];
        context(aad, nonce);
        const bool ok = ready && mbedtls_gcm_auth_decrypt(&gcm, len, nonce, 12, aad, sizeof(aad), in + len, kTagBytes,
                                                          in, out) == 0;
        if (ok) ++index;
        return ok;
    }
};

}  // namespace detail

// ---- writing: audio goes in as it is recorded, ciphertext goes to the file ----

class Writer {
public:
    ~Writer() { abort(); }

    bool open(const char *path, const Key &key, uint32_t note_id, uint32_t rate, uint16_t channels, uint16_t bits) {
        uint8_t header[kHeaderBytes];
        detail::make_header(header, key.id, note_id, rate, channels, bits, kChunkBytes);
        file_ = fopen(path, "wb");
        if (file_ == nullptr) return false;
        pending_len_ = 0;
        if (!cipher_.start(key, header) || fwrite(header, 1, kHeaderBytes, file_) != kHeaderBytes) {
            abort();
            return false;
        }
        return true;
    }

    bool append(const uint8_t *data, size_t len) {
        while (len > 0) {
            const size_t take = len < kChunkBytes - pending_len_ ? len : kChunkBytes - pending_len_;
            memcpy(pending_ + pending_len_, data, take);
            pending_len_ += take;
            data += take;
            len -= take;
            if (pending_len_ == kChunkBytes && !flush()) return false;
        }
        return true;
    }

    // Seals what is left and closes the file.
    bool finish() {
        if (file_ == nullptr) return false;
        const bool ok = pending_len_ == 0 || flush();
        const bool closed = fclose(file_) == 0;
        file_ = nullptr;
        return ok && closed;
    }

    void abort() {
        if (file_ != nullptr) fclose(file_);
        file_ = nullptr;
    }

private:
    bool flush() {
        if (!cipher_.seal(pending_, pending_len_, sealed_)) return false;
        const size_t total = pending_len_ + kTagBytes;
        pending_len_ = 0;
        return fwrite(sealed_, 1, total, file_) == total;
    }

    // The buffers live in the object, which callers allocate on the heap: a task
    // stack is too small for them.
    FILE *file_ = nullptr;
    detail::Cipher cipher_;
    uint8_t pending_[kChunkBytes];
    uint8_t sealed_[kChunkBytes + kTagBytes];
    size_t pending_len_ = 0;
};

// ---- reading (playback on the board) -----------------------------------------

class Reader {
public:
    ~Reader() { close(); }

    // Opens a note with whichever of the board's keys sealed it. Fails if the file is
    // not a CNT1 file or the board has no such key.
    bool open(const char *path) {
        close();
        struct stat info;
        if (stat(path, &info) != 0) return false;
        file_ = fopen(path, "rb");
        uint8_t header[kHeaderBytes];
        Key key;
        if (file_ == nullptr || fread(header, 1, kHeaderBytes, file_) != kHeaderBytes ||
            memcmp(header, "CNT1", 4) != 0 || header[4] != kVersion || detail::get_u16(header + 6) != kHeaderBytes ||
            !load_key_by_id(detail::get_u32(header + 8), &key) || !cipher_.start(key, header)) {
            memset(&key, 0, sizeof(key));
            close();
            return false;
        }
        memset(&key, 0, sizeof(key));
        channels_ = detail::get_u16(header + 20);
        bits_ = detail::get_u16(header + 22);
        chunk_bytes_ = detail::get_u32(header + 24);
        if (chunk_bytes_ == 0 || chunk_bytes_ > kChunkBytes) {
            close();
            return false;
        }
        remaining_ = static_cast<size_t>(info.st_size) - kHeaderBytes;
        return true;
    }

    // Reads the next chunk of audio into out (room for kChunkBytes) and returns its
    // length. 0 means the end of the note, or a chunk that did not authenticate
    // (damaged, or a recording cut short while being written): playback just stops.
    size_t read(uint8_t *out) {
        if (file_ == nullptr || remaining_ <= kTagBytes) return 0;
        const size_t take = remaining_ < chunk_bytes_ + kTagBytes ? remaining_ : chunk_bytes_ + kTagBytes;
        if (fread(sealed_, 1, take, file_) != take) return 0;
        remaining_ -= take;
        const size_t plain = take - kTagBytes;
        return cipher_.open(sealed_, plain, out) ? plain : 0;
    }

    uint16_t channels() const { return channels_; }
    uint16_t bits() const { return bits_; }

    void close() {
        if (file_ != nullptr) fclose(file_);
        file_ = nullptr;
    }

private:
    FILE *file_ = nullptr;
    detail::Cipher cipher_;
    uint8_t sealed_[kChunkBytes + kTagBytes];
    size_t remaining_ = 0;
    uint32_t chunk_bytes_ = 0;
    uint16_t channels_ = 0, bits_ = 0;
};

// ---- known-answer test -------------------------------------------------------

// Seals pcm the way Writer does, into memory. Returns the file length, or 0.
inline size_t seal_buffer(const Key &key, uint32_t note_id, uint32_t rate, uint16_t channels, uint16_t bits,
                          uint32_t chunk_bytes, const uint8_t *pcm, size_t pcm_len, uint8_t *out, size_t out_size) {
    const size_t chunks = chunk_bytes == 0 ? 0 : (pcm_len + chunk_bytes - 1) / chunk_bytes;
    if (chunk_bytes == 0 || kHeaderBytes + pcm_len + chunks * kTagBytes > out_size) return 0;
    detail::make_header(out, key.id, note_id, rate, channels, bits, chunk_bytes);
    detail::Cipher cipher;
    if (!cipher.start(key, out)) return 0;
    size_t pos = kHeaderBytes, done = 0;
    while (done < pcm_len) {
        const size_t n = pcm_len - done < chunk_bytes ? pcm_len - done : chunk_bytes;
        if (!cipher.seal(pcm + done, n, out + pos)) return 0;
        pos += n + kTagBytes;
        done += n;
    }
    return pos;
}

// Opens a whole file held in memory (the reverse of seal_buffer).
inline bool open_buffer(const Key &key, const uint8_t *file, size_t file_len, uint8_t *out, size_t out_size,
                        size_t *out_len) {
    *out_len = 0;
    if (file_len < kHeaderBytes || memcmp(file, "CNT1", 4) != 0 || detail::get_u32(file + 8) != key.id) return false;
    const uint32_t chunk_bytes = detail::get_u32(file + 24);
    if (chunk_bytes == 0 || chunk_bytes > kChunkBytes) return false;
    detail::Cipher cipher;
    if (!cipher.start(key, file)) return false;
    size_t pos = kHeaderBytes, written = 0;
    while (pos < file_len) {
        const size_t take = file_len - pos < chunk_bytes + kTagBytes ? file_len - pos : chunk_bytes + kTagBytes;
        if (take < kTagBytes || written + take - kTagBytes > out_size) return false;
        if (!cipher.open(file + pos, take - kTagBytes, out + written)) return false;
        written += take - kTagBytes;
        pos += take;
    }
    *out_len = written;
    return true;
}

}  // namespace circuit_secure
