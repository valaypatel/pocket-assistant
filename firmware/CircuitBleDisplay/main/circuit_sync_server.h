#pragma once

// Wi-Fi note sync: a short-lived HTTPS server on the board.
//
// Threat model: anything on the same Wi-Fi can reach the port while it is open,
// so the server must give it nothing.
//   * It only runs during a sync session, on a random port, and is never
//     advertised on the network.
//   * TLS with a certificate the board generated for itself. The app learns the
//     certificate's SHA-256 fingerprint and a session token over the bonded
//     (encrypted) BLE link and trusts nothing else.
//   * Every request needs the session token. A missing or wrong token, a second
//     client, or an unknown URL closes the connection without a response.
//   * Three bad attempts end the session and start a lockout.
//
// Endpoints (all authenticated, header `X-Circuit-Token`):
//   GET  /notes        "<id>,<bytes>,<epoch>\n" per unsynced note
//   GET  /notes/<id>   the note file as stored (encrypted, see circuit_crypto.h): the
//                      board never decrypts it for the phone. Supports "Range: bytes=<start>-"
//   GET  /moments/<id> the note's Moments file as stored (sealed, see circuit_moments.h), or an
//                      empty body when the note has none
//   POST /ack/<id>     marks the note synced (the file stays on the card)
//   PUT  /speak        (speak sessions only, which serve nothing else) a short 16 kHz mono 16-bit WAV
//                      the phone wants played on the board; it is kept just long enough to play
//   PUT  /firmware     (firmware sessions only, which serve nothing else) a new firmware image. It is
//                      kept on the card until the supervisor task installs it (flash is never written
//                      from the server task, whose stack is in PSRAM)

#include <arpa/inet.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/socket.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_https_server.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/pk.h"
#include "mbedtls/sha256.h"
#include "mbedtls/x509_crt.h"
#include "nvs.h"

#include "circuit_notes.h"

namespace circuit_sync {

// One line of internal-RAM numbers. "lowest" never rises, so the first stage that shows a drop is
// where the memory went.
inline void log_heap(const char *stage) {
    ESP_LOGW("CircuitHeap", "%-22s free %6u  largest %6u  lowest ever %6u", stage,
        static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)),
        static_cast<unsigned>(heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)));
}

// How many downloads the board has cut short since it started (memory, or the phone going
// away). Reported to the phone with the rest of the board's health.
inline volatile uint32_t download_stops = 0;

constexpr uint32_t kIdleTimeoutMs = 120000;
// Once the phone has started downloading, silence this long means it has gone (Wi-Fi lost, app
// closed): the session ends so the screen shows the result and the board is free again.
constexpr uint32_t kClientGoneMs = 25000;
constexpr uint32_t kLockoutMs = 30000;
constexpr int kMaxBadAttempts = 3;
constexpr size_t kChunkBytes = 4096;
constexpr size_t kMaxListed = 48;
constexpr char kSpeakPath[] = "/sdcard/SPEAK.WAV";
constexpr size_t kSpeakHeaderBytes = 44;
constexpr size_t kMaxSpeakBytes = kSpeakHeaderBytes + 16000 * 2 * 30;  // 30 seconds
constexpr char kFirmwarePath[] = "/sdcard/FIRMWARE.BIN";
constexpr size_t kMinFirmwareBytes = 256 * 1024;
constexpr size_t kMaxFirmwareBytes = 0x320000 - 0x1000;  // an app slot (partitions.csv), less a sector
constexpr char kTokenHeader[] = "X-Circuit-Token";
constexpr char kNvsNamespace[] = "circuit_tls";

struct State {
    httpd_handle_t server = nullptr;
    char cert_pem[1024] = {};
    char key_pem[512] = {};
    char fingerprint[65] = {};
    bool identity_ready = false;
    char token[33] = {};
    uint16_t port = 0;
    uint32_t client_ip = 0;  // first authenticated client; others are refused
    int bad_attempts = 0;
    int64_t last_activity_ms = 0;
    int64_t session_started_ms = 0;
    int64_t first_request_ms = 0;
    int64_t lockout_until_ms = 0;
    uint32_t total_bytes = 0;
    uint32_t only_recording = 0;  // sync just this recording (its board number); 0 = everything waiting
    uint32_t served_bytes = 0;
    uint32_t acked = 0;
    bool speak = false;                 // a session that only takes one upload from the phone (a message or firmware)
    bool firmware = false;              // ... and that upload is a firmware image
    volatile bool speak_ready = false;  // the message has arrived whole at kSpeakPath
    volatile bool firmware_ready = false;  // the image has arrived whole at kFirmwarePath
    // Set by the application. Called from the HTTP server task.
    void (*on_progress)(uint32_t percent) = nullptr;
};

inline State state;
inline const char *kTagSync = "CircuitSync";

inline int64_t now_ms() { return esp_timer_get_time() / 1000; }

inline void hex(const uint8_t *in, size_t len, char *out) {
    for (size_t i = 0; i < len; ++i) snprintf(out + i * 2, 3, "%02x", in[i]);
}

// Creates (once) a P-256 key and self-signed certificate and keeps them in NVS.
inline bool ensure_identity() {
    State &s = state;
    if (s.identity_ready) return true;

    nvs_handle_t nvs;
    bool loaded = false;
    if (nvs_open(kNvsNamespace, NVS_READWRITE, &nvs) != ESP_OK) return false;
    size_t cert_len = sizeof(s.cert_pem), key_len = sizeof(s.key_pem);
    if (nvs_get_str(nvs, "cert", s.cert_pem, &cert_len) == ESP_OK &&
        nvs_get_str(nvs, "key", s.key_pem, &key_len) == ESP_OK) {
        loaded = true;
    }

    if (!loaded) {
        mbedtls_entropy_context entropy;
        mbedtls_ctr_drbg_context drbg;
        mbedtls_pk_context key;
        mbedtls_x509write_cert crt;
        mbedtls_entropy_init(&entropy);
        mbedtls_ctr_drbg_init(&drbg);
        mbedtls_pk_init(&key);
        mbedtls_x509write_crt_init(&crt);
        const char *seed = "circuit-sync";
        bool ok = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                      reinterpret_cast<const unsigned char *>(seed), strlen(seed)) == 0 &&
                  mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY)) == 0 &&
                  mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key),
                      mbedtls_ctr_drbg_random, &drbg) == 0;
        if (ok) {
            uint8_t serial[8];
            esp_fill_random(serial, sizeof(serial));
            serial[0] &= 0x7f;
            mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
            mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
            mbedtls_x509write_crt_set_subject_key(&crt, &key);
            mbedtls_x509write_crt_set_issuer_key(&crt, &key);
            ok = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial)) == 0 &&
                 mbedtls_x509write_crt_set_subject_name(&crt, "CN=Circuit") == 0 &&
                 mbedtls_x509write_crt_set_issuer_name(&crt, "CN=Circuit") == 0 &&
                 // Validity is irrelevant: the app pins the fingerprint.
                 mbedtls_x509write_crt_set_validity(&crt, "20250101000000", "20450101000000") == 0 &&
                 mbedtls_x509write_crt_pem(&crt, reinterpret_cast<unsigned char *>(s.cert_pem),
                     sizeof(s.cert_pem), mbedtls_ctr_drbg_random, &drbg) == 0 &&
                 mbedtls_pk_write_key_pem(&key, reinterpret_cast<unsigned char *>(s.key_pem),
                     sizeof(s.key_pem)) == 0;
        }
        mbedtls_x509write_crt_free(&crt);
        mbedtls_pk_free(&key);
        mbedtls_ctr_drbg_free(&drbg);
        mbedtls_entropy_free(&entropy);
        if (!ok) {
            ESP_LOGE(kTagSync, "Could not create sync certificate");
            nvs_close(nvs);
            return false;
        }
        nvs_set_str(nvs, "cert", s.cert_pem);
        nvs_set_str(nvs, "key", s.key_pem);
        nvs_commit(nvs);
    }
    nvs_close(nvs);

    mbedtls_x509_crt parsed;
    mbedtls_x509_crt_init(&parsed);
    const int parse = mbedtls_x509_crt_parse(&parsed, reinterpret_cast<const unsigned char *>(s.cert_pem),
        strlen(s.cert_pem) + 1);
    if (parse != 0) {
        mbedtls_x509_crt_free(&parsed);
        return false;
    }
    uint8_t digest[32];
    mbedtls_sha256(parsed.raw.p, parsed.raw.len, digest, 0);
    hex(digest, sizeof(digest), s.fingerprint);
    mbedtls_x509_crt_free(&parsed);
    s.identity_ready = true;
    return true;
}

inline bool token_matches(const char *given) {
    // Constant time, so response timing does not leak how much matched.
    const size_t want = strlen(state.token);
    size_t diff = strlen(given) ^ want;
    for (size_t i = 0; i < want; ++i) diff |= static_cast<uint8_t>(given[i] ^ state.token[i]);
    return diff == 0;
}

inline void note_bad_attempt() {
    State &s = state;
    if (++s.bad_attempts >= kMaxBadAttempts) {
        s.lockout_until_ms = now_ms() + kLockoutMs;
        ESP_LOGW(kTagSync, "Too many bad requests; closing sync session");
    }
}

// Returns true only for the token holder on the first authenticated address.
// On failure nothing is sent: the caller returns ESP_FAIL and the server drops
// the connection.
inline bool authorize(httpd_req_t *req) {
    State &s = state;
    if (s.bad_attempts >= kMaxBadAttempts) return false;

    char given[48] = {};
    if (httpd_req_get_hdr_value_str(req, kTokenHeader, given, sizeof(given)) != ESP_OK || !token_matches(given)) {
        note_bad_attempt();
        return false;
    }
    sockaddr_in6 peer6 = {};
    socklen_t length = sizeof(peer6);
    uint32_t ip = 0;
    if (getpeername(httpd_req_to_sockfd(req), reinterpret_cast<sockaddr *>(&peer6), &length) == 0) {
        if (peer6.sin6_family == AF_INET6) {  // IPv4 peers appear as ::ffff:a.b.c.d
            memcpy(&ip, reinterpret_cast<const uint8_t *>(&peer6.sin6_addr) + 12, sizeof(ip));
        } else {
            ip = reinterpret_cast<sockaddr_in *>(&peer6)->sin_addr.s_addr;
        }
    }
    if (ip == 0) return false;
    if (s.client_ip != 0 && s.client_ip != ip) {
        note_bad_attempt();
        return false;
    }
    s.client_ip = ip;
    s.last_activity_ms = now_ms();
    if (s.first_request_ms == 0) s.first_request_ms = s.last_activity_ms;
    return true;
}

inline uint32_t id_after(const char *uri, const char *prefix) {
    const size_t n = strlen(prefix);
    if (strncmp(uri, prefix, n) != 0) return 0;
    char *end = nullptr;
    const unsigned long id = strtoul(uri + n, &end, 10);
    return (end == uri + n || (*end != '\0' && *end != '?')) ? 0 : static_cast<uint32_t>(id);
}

inline esp_err_t list_handler(httpd_req_t *req) {
    if (!authorize(req)) return ESP_FAIL;
    circuit_notes::Note notes[kMaxListed];
    const size_t count = circuit_notes::list_unsynced_of(notes, kMaxListed, state.only_recording);
    // "<id>,<bytes>,<recorded>" and, for a one-minute part of a longer recording,
    // ",<first part's id>,<part number>,<1 if last>". A phone that does not know parts reads the first three.
    constexpr size_t kLine = 72;
    char *body = static_cast<char *>(malloc(count * kLine + 1));
    if (body == nullptr) return ESP_FAIL;
    size_t used = 0;
    for (size_t i = 0; i < count; ++i) {
        used += snprintf(body + used, kLine, "%lu,%lu,%lld", static_cast<unsigned long>(notes[i].id),
            static_cast<unsigned long>(notes[i].bytes), static_cast<long long>(notes[i].recorded));
        circuit_notes::Group group;
        if (circuit_notes::read_group(notes[i].id, &group)) {
            used += snprintf(body + used, kLine, ",%lu,%lu,%d", static_cast<unsigned long>(group.first),
                static_cast<unsigned long>(group.part), group.final ? 1 : 0);
        }
        body[used++] = '\n';
    }
    body[used] = '\0';
    httpd_resp_set_type(req, "text/plain");
    const esp_err_t status = httpd_resp_send(req, body, used);
    free(body);
    return status;
}

inline esp_err_t note_handler(httpd_req_t *req) {
    if (!authorize(req)) return ESP_FAIL;
    const uint32_t id = id_after(req->uri, "/notes/");
    circuit_notes::Note note;
    if (id == 0 || !circuit_notes::describe(id, &note)) {
        ESP_LOGW("CircuitSync", "Download refused: note %lu not found on the card", static_cast<unsigned long>(id));
        return ESP_FAIL;
    }

    uint32_t start = 0;
    char range[48] = {};
    if (httpd_req_get_hdr_value_str(req, "Range", range, sizeof(range)) == ESP_OK &&
        strncmp(range, "bytes=", 6) == 0) {
        start = static_cast<uint32_t>(strtoul(range + 6, nullptr, 10));
        if (start >= note.bytes) {
            ESP_LOGW("CircuitSync", "Download refused: note %lu asked from byte %lu but has %lu", static_cast<unsigned long>(id),
                static_cast<unsigned long>(start), static_cast<unsigned long>(note.bytes));
            return ESP_FAIL;
        }
    }

    log_heap(start > 0 ? "sync: note (resume)" : "sync: note start");
    char path[48];
    circuit_notes::note_path(note, path, sizeof(path));
    FILE *file = fopen(path, "rb");
    uint8_t *buffer = static_cast<uint8_t *>(malloc(kChunkBytes));
    if (file == nullptr || buffer == nullptr) {
        ESP_LOGW("CircuitSync", "Download refused: note %lu file %s, buffer %s (internal RAM free %u, largest %u)",
            static_cast<unsigned long>(id), file == nullptr ? "would not open" : "ok", buffer == nullptr ? "not allocated" : "ok",
            static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
            static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)));
        if (file != nullptr) fclose(file);
        free(buffer);
        return ESP_FAIL;
    }
    fseek(file, start, SEEK_SET);

    httpd_resp_set_type(req, note.encrypted ? "application/octet-stream" : "audio/wav");
    if (start > 0) {
        char content_range[64];
        snprintf(content_range, sizeof(content_range), "bytes %lu-%lu/%lu", static_cast<unsigned long>(start),
            static_cast<unsigned long>(note.bytes - 1), static_cast<unsigned long>(note.bytes));
        httpd_resp_set_status(req, "206 Partial Content");
        httpd_resp_set_hdr(req, "Content-Range", content_range);
    }
    esp_err_t status = ESP_OK;
    size_t read = 0;
    uint32_t position = start;
    int read_failures = 0;
    while (true) {
        read = fread(buffer, 1, kChunkBytes, file);
        if (read == 0) {
            // A read that fails while internal RAM is nearly gone (the SD driver cannot get its small
            // buffer) looks like the end of the file. Wait a moment and read the same place again.
            if (ferror(file) && position < note.bytes && ++read_failures <= 5) {
                clearerr(file);
                vTaskDelay(pdMS_TO_TICKS(60));
                fseek(file, position, SEEK_SET);
                continue;
            }
            break;
        }
        read_failures = 0;
        position += read;
        status = httpd_resp_send_chunk(req, reinterpret_cast<const char *>(buffer), read);
        if (status != ESP_OK) break;
        state.last_activity_ms = now_ms();
        state.served_bytes += read;
        if (state.served_bytes / (256 * 1024) != (state.served_bytes - read) / (256 * 1024)) log_heap("sync: transferring");
        if (state.on_progress != nullptr && state.total_bytes > 0) {
            const uint64_t percent = static_cast<uint64_t>(state.served_bytes) * 100 / state.total_bytes;
            state.on_progress(percent > 100 ? 100 : static_cast<uint32_t>(percent));
        }
    }
    if (status == ESP_OK) status = httpd_resp_send_chunk(req, nullptr, 0);
    if (status != ESP_OK) {
        download_stops = download_stops + 1;
        ESP_LOGW("CircuitSync", "Download of note %lu stopped after %lu bytes: internal RAM free %u, largest block %u, lowest ever %u",
            static_cast<unsigned long>(id), static_cast<unsigned long>(state.served_bytes),
            static_cast<unsigned>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL)),
            static_cast<unsigned>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL)),
            static_cast<unsigned>(heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL)));
    }
    fclose(file);
    free(buffer);
    return status;
}

// A note's Moments (bookmarks added with the lower key). The file is small (under 600 bytes) and
// sealed, so it goes out as it is stored. A note without one answers with an empty body, so the
// phone never has to treat "none" as an error.
inline esp_err_t moments_handler(httpd_req_t *req) {
    if (!authorize(req)) return ESP_FAIL;
    const uint32_t id = id_after(req->uri, "/moments/");
    if (id == 0) return ESP_FAIL;
    char path[48];
    circuit_notes::path_for(id, "MOM", path, sizeof(path));
    uint8_t file[640];
    size_t length = 0;
    if (FILE *in = fopen(path, "rb")) {
        length = fread(file, 1, sizeof(file), in);
        fclose(in);
    }
    httpd_resp_set_type(req, "application/octet-stream");
    return httpd_resp_send(req, reinterpret_cast<const char *>(file), length);
}

inline esp_err_t ack_handler(httpd_req_t *req) {
    if (!authorize(req)) return ESP_FAIL;
    const uint32_t id = id_after(req->uri, "/ack/");
    circuit_notes::Note note;
    if (id == 0 || !circuit_notes::describe(id, &note) || !circuit_notes::mark_synced(id)) return ESP_FAIL;
    ++state.acked;
    return httpd_resp_send(req, "ok", 2);
}

inline bool speak_header_ok(const uint8_t *h, size_t size) {
    if (size != kSpeakHeaderBytes) return false;
    auto u16 = [&](size_t at) { return static_cast<uint16_t>(h[at] | (h[at + 1] << 8)); };
    auto u32 = [&](size_t at) { return static_cast<uint32_t>(u16(at)) | (static_cast<uint32_t>(u16(at + 2)) << 16); };
    return memcmp(h, "RIFF", 4) == 0 && memcmp(h + 8, "WAVE", 4) == 0 && memcmp(h + 12, "fmt ", 4) == 0 &&
           u32(16) == 16 && u16(20) == 1 && u16(22) == 1 && u32(24) == 16000 && u16(34) == 16 &&
           memcmp(h + 36, "data", 4) == 0;
}

// Takes the spoken message: written to the card as it arrives, checked, and only then announced.
inline esp_err_t speak_handler(httpd_req_t *req) {
    if (!authorize(req)) return ESP_FAIL;
    State &s = state;
    const size_t total = req->content_len;
    if (!s.speak || s.speak_ready || total <= kSpeakHeaderBytes || total > kMaxSpeakBytes) return ESP_FAIL;
    auto *buffer = static_cast<uint8_t *>(heap_caps_malloc(kChunkBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    FILE *file = buffer != nullptr ? fopen(kSpeakPath, "wb") : nullptr;
    bool ok = file != nullptr;
    size_t left = total;
    int timeouts = 0;
    while (ok && left > 0) {
        const int got = httpd_req_recv(req, reinterpret_cast<char *>(buffer), left < kChunkBytes ? left : kChunkBytes);
        if (got == HTTPD_SOCK_ERR_TIMEOUT && ++timeouts < 3) continue;
        if (got <= 0 || fwrite(buffer, 1, got, file) != static_cast<size_t>(got)) { ok = false; break; }
        left -= got;
        s.last_activity_ms = now_ms();
    }
    if (file != nullptr) fclose(file);
    if (buffer != nullptr) heap_caps_free(buffer);
    if (ok) {
        uint8_t header[kSpeakHeaderBytes];
        FILE *check = fopen(kSpeakPath, "rb");
        ok = check != nullptr && speak_header_ok(header, fread(header, 1, sizeof(header), check));
        if (check != nullptr) fclose(check);
    }
    if (!ok) {
        remove(kSpeakPath);
        return ESP_FAIL;
    }
    s.speak_ready = true;
    return httpd_resp_send(req, "ok", 2);
}

// Takes a firmware image: written to the card as it arrives. The caller (a task with its stack in internal
// RAM) installs it after the session closes.
inline esp_err_t firmware_handler(httpd_req_t *req) {
    if (!authorize(req)) return ESP_FAIL;
    State &s = state;
    const size_t total = req->content_len;
    if (!s.firmware || s.firmware_ready || total < kMinFirmwareBytes || total > kMaxFirmwareBytes) return ESP_FAIL;
    auto *buffer = static_cast<uint8_t *>(heap_caps_malloc(kChunkBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    FILE *file = buffer != nullptr ? fopen(kFirmwarePath, "wb") : nullptr;
    bool ok = file != nullptr;
    size_t left = total;
    int timeouts = 0;
    bool first = true;
    while (ok && left > 0) {
        const int got = httpd_req_recv(req, reinterpret_cast<char *>(buffer), left < kChunkBytes ? left : kChunkBytes);
        if (got == HTTPD_SOCK_ERR_TIMEOUT && ++timeouts < 3) continue;
        if (got <= 0 || fwrite(buffer, 1, got, file) != static_cast<size_t>(got)) { ok = false; break; }
        if (first && buffer[0] != 0xE9) { ok = false; break; }  // not an ESP image
        first = false;
        left -= got;
        s.last_activity_ms = now_ms();
        // The first half of the progress figure: the image arriving (the second half is it being installed).
        if (s.on_progress != nullptr) s.on_progress(static_cast<uint32_t>((total - left) * 50 / total));
    }
    if (file != nullptr && fclose(file) != 0) ok = false;
    if (buffer != nullptr) heap_caps_free(buffer);
    if (!ok) {
        remove(kFirmwarePath);
        return ESP_FAIL;
    }
    s.firmware_ready = true;
    return httpd_resp_send(req, "ok", 2);
}

inline esp_err_t not_found_handler(httpd_req_t *, httpd_err_code_t) {
    note_bad_attempt();
    return ESP_FAIL;  // close the connection with no response
}

inline bool wifi_ip(char *out, size_t size) {
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    esp_netif_ip_info_t info;
    if (netif == nullptr || esp_netif_get_ip_info(netif, &info) != ESP_OK || info.ip.addr == 0) return false;
    snprintf(out, size, IPSTR, IP2STR(&info.ip));
    return true;
}

inline bool is_open() { return state.server != nullptr; }
inline bool locked_out() { return now_ms() < state.lockout_until_ms; }
inline bool expired() {
    return is_open() && (state.bad_attempts >= kMaxBadAttempts ||
                         now_ms() - state.last_activity_ms >
                             (state.first_request_ms != 0 ? kClientGoneMs : kIdleTimeoutMs));
}

inline void close_session() {
    if (state.server != nullptr) {
        httpd_ssl_stop(state.server);
        state.server = nullptr;
    }
    memset(state.token, 0, sizeof(state.token));
    state.client_ip = 0;
    state.only_recording = 0;
    state.speak = false;
    state.firmware = false;
}

// Files still waiting that this session is for: one recording's, or everything's.
inline size_t waiting_in_session() { return circuit_notes::count_unsynced_of(state.only_recording); }

// Starts a session. On success fills the port, token and fingerprint the app
// needs, and the number and size of notes waiting.
inline bool open_session(uint16_t *port, char *token, size_t token_size, const char **fingerprint,
                         uint32_t *note_count, uint32_t *total_bytes, uint32_t only_recording = 0, bool speak = false,
                         bool firmware = false) {
    State &s = state;
    log_heap("sync: before session");
    if (is_open() || locked_out() || token_size < sizeof(s.token) || !ensure_identity()) return false;
    log_heap("sync: identity ready");

    circuit_notes::Note notes[kMaxListed];
    const bool upload = speak || firmware;
    const size_t count = upload ? 0 : circuit_notes::list_unsynced_of(notes, kMaxListed, only_recording);
    if (count == 0 && !upload) return false;
    s.speak = upload;
    s.firmware = firmware;
    s.speak_ready = false;
    s.firmware_ready = false;
    s.only_recording = only_recording;
    s.total_bytes = 0;
    for (size_t i = 0; i < count; ++i) s.total_bytes += notes[i].bytes;
    s.served_bytes = 0;
    s.acked = 0;
    s.bad_attempts = 0;
    s.client_ip = 0;

    uint8_t raw[16];
    esp_fill_random(raw, sizeof(raw));
    hex(raw, sizeof(raw), s.token);
    s.port = static_cast<uint16_t>(20000 + esp_random() % 40000);

    httpd_ssl_config_t config = HTTPD_SSL_CONFIG_DEFAULT();
    config.servercert = reinterpret_cast<const uint8_t *>(s.cert_pem);
    config.servercert_len = strlen(s.cert_pem) + 1;
    config.prvtkey_pem = reinterpret_cast<const uint8_t *>(s.key_pem);
    config.prvtkey_len = strlen(s.key_pem) + 1;
    config.port_secure = s.port;
    config.httpd.stack_size = 10240;
    // The server's stack lives in PSRAM: internal RAM is the scarce part during a sync. Nothing the
    // server task runs writes flash (the certificate is stored by the task that opens the session).
    config.httpd.task_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    config.httpd.max_open_sockets = 2;
    config.httpd.lru_purge_enable = true;
    config.httpd.recv_wait_timeout = 10;
    config.httpd.send_wait_timeout = 10;
    config.httpd.uri_match_fn = httpd_uri_match_wildcard;
    config.httpd.max_uri_handlers = 5;
    if (httpd_ssl_start(&s.server, &config) != ESP_OK) {
        s.server = nullptr;
        return false;
    }
    log_heap("sync: server up");
    static const httpd_uri_t firmware_uri = {.uri = "/firmware", .method = HTTP_PUT, .handler = firmware_handler, .user_ctx = nullptr};
    static const httpd_uri_t speak_uri = {.uri = "/speak", .method = HTTP_PUT, .handler = speak_handler, .user_ctx = nullptr};
    static const httpd_uri_t list = {.uri = "/notes", .method = HTTP_GET, .handler = list_handler, .user_ctx = nullptr};
    static const httpd_uri_t note = {.uri = "/notes/*", .method = HTTP_GET, .handler = note_handler, .user_ctx = nullptr};
    static const httpd_uri_t ack = {.uri = "/ack/*", .method = HTTP_POST, .handler = ack_handler, .user_ctx = nullptr};
    static const httpd_uri_t moments = {.uri = "/moments/*", .method = HTTP_GET, .handler = moments_handler, .user_ctx = nullptr};
    if (firmware) {
        httpd_register_uri_handler(s.server, &firmware_uri);
    } else if (speak) {
        httpd_register_uri_handler(s.server, &speak_uri);
    } else {
        httpd_register_uri_handler(s.server, &list);
        httpd_register_uri_handler(s.server, &note);
        httpd_register_uri_handler(s.server, &moments);
        httpd_register_uri_handler(s.server, &ack);
    }
    httpd_register_err_handler(s.server, HTTPD_404_NOT_FOUND, not_found_handler);
    httpd_register_err_handler(s.server, HTTPD_405_METHOD_NOT_ALLOWED, not_found_handler);

    s.last_activity_ms = now_ms();
    s.session_started_ms = s.last_activity_ms;
    s.first_request_ms = 0;
    *port = s.port;
    snprintf(token, token_size, "%s", s.token);
    *fingerprint = s.fingerprint;
    *note_count = static_cast<uint32_t>(count);
    *total_bytes = s.total_bytes;
    return true;
}

}  // namespace circuit_sync
