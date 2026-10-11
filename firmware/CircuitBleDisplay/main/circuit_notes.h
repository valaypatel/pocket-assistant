#pragma once

// Per-note storage on the SD card.
//
//   /sdcard/NOTES/N0000001.ENC   encrypted note (circuit_crypto.h), one file per note
//   /sdcard/NOTES/N0000001.WAV   a note from older firmware, left exactly as it was: plain,
//                                 still synced and played, never rewritten or removed
//   /sdcard/NOTES/N0000001.SYN   empty marker: the app has confirmed this note
//   /sdcard/NOTES/N0000001.PRT   text "<first> <part> <final>": this note is one minute of a longer
//                                 recording. <first> is the number of the recording's first part
//                                 (its recording ID), <part> counts from 1, <final> is 1 on the
//                                 last part. Parts are ordinary notes with consecutive numbers.
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

#ifndef CIRCUIT_NOTES_DIR  // a test on a computer points this at a temporary folder
#define CIRCUIT_NOTES_DIR "/sdcard/NOTES"
#endif
constexpr char kDir[] = CIRCUIT_NOTES_DIR;
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

// True if note `id` also has an encrypted file. Kept out of line so its path buffer is
// not on the stack while the caller's callback runs: listing runs on a task with little
// stack, inside filesystem calls that are already deep.
__attribute__((noinline)) inline bool has_encrypted_file(uint32_t id) {
    char path[48];
    path_for(id, "ENC", path, sizeof(path));
    return exists(path);
}

// Calls fn(id) once per note. If a note exists both ways (an encryption that was
// interrupted after the new file was complete), the encrypted one is the note.
template <typename Fn>
inline void for_each_note(Fn fn) {
    DIR *dir = opendir(kDir);
    if (dir == nullptr) return;
    while (dirent *entry = readdir(dir)) {
        unsigned long id = 0;
        char ext[4] = {};
        if (sscanf(entry->d_name, "N%7lu.%3s", &id, ext) != 2 || id == 0) continue;
        const bool encrypted = strcasecmp(ext, "ENC") == 0;
        if (encrypted || (strcasecmp(ext, "WAV") == 0 && !has_encrypted_file(static_cast<uint32_t>(id)))) {
            fn(static_cast<uint32_t>(id));
        }
    }
    closedir(dir);
}

// ---- recordings made of one-minute parts ----------------------------------

struct Group {
    uint32_t first;  // number of the recording's first part
    uint32_t part;   // 1-based
    bool final;      // the last part of the recording
};

inline bool write_group(uint32_t id, const Group &group) {
    char path[48];
    path_for(id, "PRT", path, sizeof(path));
    FILE *file = fopen(path, "wb");
    if (file == nullptr) return false;
    const bool ok = fprintf(file, "%lu %lu %d\n", static_cast<unsigned long>(group.first),
                            static_cast<unsigned long>(group.part), group.final ? 1 : 0) > 0;
    return fclose(file) == 0 && ok;
}

// False for a note that is not a part (a plain single-file note).
__attribute__((noinline)) inline bool read_group(uint32_t id, Group *group) {
    char path[48];
    path_for(id, "PRT", path, sizeof(path));
    FILE *file = fopen(path, "rb");
    if (file == nullptr) return false;
    unsigned long first = 0, part = 0;
    int final = 0;
    const bool ok = fscanf(file, "%lu %lu %d", &first, &part, &final) == 3 && first != 0 && part != 0;
    fclose(file);
    if (!ok) return false;
    group->first = static_cast<uint32_t>(first);
    group->part = static_cast<uint32_t>(part);
    group->final = final != 0;
    return true;
}

// The recording a note belongs to: its first part's number for a part of a longer recording,
// its own number for a plain note. The app calls this number the recording's board number.
inline uint32_t recording_of(uint32_t id) {
    Group group;
    return read_group(id, &group) ? group.first : id;
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

// Fills `out` with notes the app has not yet confirmed, oldest first. With `recording` set, only the
// files of that recording (all its parts, or the one plain note); 0 means everything waiting.
inline size_t list_unsynced_of(Note *out, size_t capacity, uint32_t recording) {
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (count < capacity && describe(id, &note) && !note.synced &&
            (recording == 0 || recording_of(id) == recording)) {
            out[count++] = note;
        }
    });
    std::sort(out, out + count, [](const Note &a, const Note &b) { return a.id < b.id; });
    return count;
}

inline size_t list_unsynced(Note *out, size_t capacity) { return list_unsynced_of(out, capacity, 0); }

inline size_t count_unsynced_of(uint32_t recording) {
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (describe(id, &note) && !note.synced && (recording == 0 || recording_of(id) == recording)) ++count;
    });
    return count;
}

inline size_t count_unsynced() { return count_unsynced_of(0); }

// How many recordings have something waiting, as a person counts them: the one-minute parts of
// a long recording are one recording, however many of them have not synced yet. (count_unsynced()
// counts files, which is what the sync itself works through.)
inline size_t count_unsynced_recordings() {
    uint32_t firsts[16];
    size_t seen = 0, others = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (!describe(id, &note) || note.synced) return;
        Group group;
        if (!read_group(id, &group)) {
            ++others;
            return;
        }
        for (size_t i = 0; i < seen; ++i) {
            if (firsts[i] == group.first) return;
        }
        if (seen < 16) firsts[seen++] = group.first;
        else ++others;  // too many different recordings to tell apart: count each part
    });
    return seen + others;
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
    path_for(id, "PRT", path, sizeof(path));
    remove(path);
    return removed;
}

// Deletes notes the app has confirmed (the file and its marker) and returns how
// many were removed. Notes still waiting to sync are never touched.
// Removes the oldest recording (every part of it) that the phone has confirmed, to make room on the
// card. A recording with any part still waiting is never touched. Returns how many notes it removed,
// 0 when nothing is old enough to go.
inline size_t remove_oldest_synced_recording() {
    uint32_t oldest = 0;
    for_each_note([&](uint32_t id) {
        Note note;
        if (!describe(id, &note) || !note.synced) return;
        if (count_unsynced_of(recording_of(id)) != 0) return;
        if (oldest == 0 || id < oldest) oldest = id;
    });
    if (oldest == 0) return 0;
    const uint32_t recording = recording_of(oldest);
    uint32_t doomed[128];
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        if (count < 128 && recording_of(id) == recording) doomed[count++] = id;
    });
    size_t removed = 0;
    for (size_t i = 0; i < count; ++i) removed += remove_note(doomed[i]) ? 1 : 0;
    return removed;
}

// Forgets which notes the phone has confirmed, so every note on the card is offered again.
// Returns how many notes were marked unsynced.
inline size_t mark_all_unsynced() {
    uint32_t ids[256];
    size_t count = 0;
    for_each_note([&](uint32_t id) {
        if (count < 256) ids[count++] = id;
    });
    size_t changed = 0;
    for (size_t i = 0; i < count; ++i) {
        char marker[48];
        path_for(ids[i], "SYN", marker, sizeof(marker));
        if (unlink(marker) == 0) ++changed;
    }
    return changed;
}

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

// A recording cut short by power loss leaves its last part marked "not final", and the app
// would wait for a part that is never coming. Nothing is recording at boot, so close the
// recording at its last part that holds audio.
inline void finish_interrupted_recordings() {
    uint32_t open_ends[16];
    size_t count = 0;
    DIR *dir = opendir(kDir);
    if (dir == nullptr) return;
    while (dirent *entry = readdir(dir)) {
        unsigned long id = 0;
        char ext[4] = {};
        if (sscanf(entry->d_name, "N%7lu.%3s", &id, ext) != 2 || id == 0 || strcasecmp(ext, "PRT") != 0) continue;
        Group group;
        if (read_group(static_cast<uint32_t>(id), &group) && !group.final && count < 16) {
            char next[48];
            path_for(static_cast<uint32_t>(id) + 1, "PRT", next, sizeof(next));
            if (!exists(next)) open_ends[count++] = static_cast<uint32_t>(id);
        }
    }
    closedir(dir);
    for (size_t i = 0; i < count; ++i) {
        uint32_t id = open_ends[i];
        Group group;
        if (!read_group(id, &group)) continue;
        Note note;
        if (!describe(id, &note) && group.part > 1) {  // the part never got any audio: drop it
            remove_note(id);
            --id;
            if (!read_group(id, &group)) continue;
        }
        group.final = true;
        write_group(id, group);
    }
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
    finish_interrupted_recordings();
}

}  // namespace circuit_notes
