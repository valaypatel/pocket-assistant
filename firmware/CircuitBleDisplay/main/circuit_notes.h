#pragma once

// Per-note storage on the SD card.
//
//   /sdcard/NOTES/N0000001.ENC   encrypted note (circuit_crypto.h), one file per note
//   /sdcard/NOTES/N0000001.WAV   a note from older firmware, left exactly as it was: plain,
//                                 still synced and played, never rewritten or removed
//   /sdcard/NOTES/N0000001.SYN   empty marker: the app has confirmed this note
//
// 8.3 names keep this independent of long-filename support. A note's recording
// time is the file's modification time. Notes are never deleted by the firmware
// on its own; cleaning is a separate, deliberate step.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include "nvs.h"

namespace circuit_notes {

constexpr char kDir[] = "/sdcard/NOTES";
constexpr char kLegacyFile[] = "/sdcard/CIRCUIT.WAV";
constexpr size_t kWavHeaderBytes = 44;
// An encrypted file with no audio is a 44-byte header and one 16-byte tag.
constexpr size_t kEmptyEncBytes = 44 + 16;

struct Note {
    uint32_t id;
    uint32_t bytes;   // total file size: ciphertext for .ENC, a WAV with its header for .WAV
    int64_t recorded; // epoch seconds (0 if the clock was not set)
    bool synced;
    bool encrypted;   // .ENC (true) or a plain .WAV from older firmware
};

inline void path_for(uint32_t id, const char *ext, char *out, size_t size) {
    snprintf(out, size, "%s/N%07lu.%s", kDir, static_cast<unsigned long>(id), ext);
}

inline bool exists(const char *path) {
    struct stat info;
    return stat(path, &info) == 0;
}

// Calls fn(id, encrypted) for every N#######.ENC and N#######.WAV in the folder.
template <typename Fn>
inline void for_each_file(Fn fn) {
    DIR *dir = opendir(kDir);
    if (dir == nullptr) return;
    while (dirent *entry = readdir(dir)) {
        unsigned long id = 0;
        char ext[4] = {};
        if (sscanf(entry->d_name, "N%7lu.%3s", &id, ext) != 2 || id == 0) continue;
        if (strcasecmp(ext, "ENC") == 0) fn(static_cast<uint32_t>(id), true);
        else if (strcasecmp(ext, "WAV") == 0) fn(static_cast<uint32_t>(id), false);
    }
    closedir(dir);
}

// Calls fn(id) for every plain WAV (older firmware).
template <typename Fn>
inline void for_each_wav(Fn fn) {
    for_each_file([&](uint32_t id, bool encrypted) { if (!encrypted) fn(id); });
}

// Calls fn(id) once per note. If a note exists both ways (an encryption that was
// interrupted after the new file was complete), the encrypted one is the note.
template <typename Fn>
inline void for_each_note(Fn fn) {
    for_each_file([&](uint32_t id, bool encrypted) {
        if (encrypted) { fn(id); return; }
        char twin[48];
        path_for(id, "ENC", twin, sizeof(twin));
        if (!exists(twin)) fn(id);
    });
}

inline uint32_t newest_id() {
    uint32_t newest = 0;
    for_each_file([&](uint32_t id, bool) { if (id > newest) newest = id; });
    return newest;
}

// A recording interrupted by power loss leaves a header with a zero length.
// Treat whatever audio reached the card as the note.
inline void repair_header(uint32_t id) {
    char path[48];
    path_for(id, "WAV", path, sizeof(path));
    FILE *file = fopen(path, "r+b");
    if (file == nullptr) return;
    fseek(file, 0, SEEK_END);
    const long size = ftell(file);
    uint32_t data_size = 0;
    fseek(file, 40, SEEK_SET);
    const bool ok = fread(&data_size, sizeof(data_size), 1, file) == 1;
    if (ok && size > static_cast<long>(kWavHeaderBytes) &&
        data_size != static_cast<uint32_t>(size) - kWavHeaderBytes) {
        const uint32_t fixed = static_cast<uint32_t>(size) - kWavHeaderBytes;
        const uint32_t riff = fixed + kWavHeaderBytes - 8;
        fseek(file, 4, SEEK_SET);
        fwrite(&riff, sizeof(riff), 1, file);
        fseek(file, 40, SEEK_SET);
        fwrite(&fixed, sizeof(fixed), 1, file);
    }
    fclose(file);
}

// Creates the folder, adopts the single-file recording from older firmware as
// note 1, and repairs headers. Call once after the SD card is mounted.
inline void init() {
    mkdir(kDir, 0777);
    if (exists(kLegacyFile) && newest_id() == 0) {
        char path[48];
        path_for(1, "WAV", path, sizeof(path));
        rename(kLegacyFile, path);
    }
    for_each_wav([](uint32_t id) { repair_header(id); });
}

// Path for the next note. Ids only ever grow, so a name is never reused.
// Hands out the next note number. The last number is kept in NVS as well, so
// numbers keep growing even after every note has been cleaned off the card and
// the phone can use a number to recognise a recording.
inline uint32_t allocate_id() {
    uint32_t next = newest_id() + 1;
    nvs_handle_t handle;
    if (nvs_open("circuit_notes", NVS_READWRITE, &handle) == ESP_OK) {
        uint32_t last = 0;
        nvs_get_u32(handle, "last_id", &last);
        if (last + 1 > next) next = last + 1;
        nvs_set_u32(handle, "last_id", next);
        nvs_commit(handle);
        nvs_close(handle);
    }
    return next;
}

inline bool describe(uint32_t id, Note *note) {
    char path[48];
    struct stat info;
    path_for(id, "ENC", path, sizeof(path));
    const bool encrypted = stat(path, &info) == 0 && info.st_size > static_cast<off_t>(kEmptyEncBytes);
    if (!encrypted) {
        path_for(id, "WAV", path, sizeof(path));
        if (stat(path, &info) != 0 || info.st_size <= static_cast<off_t>(kWavHeaderBytes)) return false;
    }
    char marker[48];
    path_for(id, "SYN", marker, sizeof(marker));
    note->id = id;
    note->encrypted = encrypted;
    note->bytes = static_cast<uint32_t>(info.st_size);
    note->recorded = info.st_mtime > 1704067200 ? static_cast<int64_t>(info.st_mtime) : 0;
    note->synced = exists(marker);
    return true;
}

// The file that holds a note.
inline void note_path(const Note &note, char *out, size_t size) {
    path_for(note.id, note.encrypted ? "ENC" : "WAV", out, size);
}

// Fills `out` with notes the app has not yet confirmed, oldest first.
inline size_t list_unsynced(Note *out, size_t capacity) {
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (count < capacity && describe(id, &note) && !note.synced) out[count++] = note;
    });
    std::sort(out, out + count, [](const Note &a, const Note &b) { return a.id < b.id; });
    return count;
}

inline size_t count_unsynced() {
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (describe(id, &note) && !note.synced) ++count;
    });
    return count;
}

inline bool mark_synced(uint32_t id) {
    char marker[48];
    path_for(id, "SYN", marker, sizeof(marker));
    FILE *file = fopen(marker, "wb");
    if (file == nullptr) return false;
    fclose(file);
    return true;
}

// Deletes one note (its file, in either form, and its marker). Returns true if a
// file was removed; a note that is already gone is not an error.
inline bool remove_note(uint32_t id) {
    char path[48];
    path_for(id, "ENC", path, sizeof(path));
    bool removed = remove(path) == 0;
    path_for(id, "WAV", path, sizeof(path));
    removed = (remove(path) == 0) || removed;
    path_for(id, "SYN", path, sizeof(path));
    remove(path);
    return removed;
}

// Deletes notes the app has confirmed (the file and its marker) and returns how
// many were removed. Notes still waiting to sync are never touched.
inline size_t clean_synced() {
    uint32_t doomed[128];
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (count < 128 && describe(id, &note) && note.synced) doomed[count++] = id;
    });
    size_t removed = 0;
    for (size_t i = 0; i < count; ++i) removed += remove_note(doomed[i]) ? 1 : 0;
    return removed;
}

}  // namespace circuit_notes
