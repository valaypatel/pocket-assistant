package com.valay.circuit.short_circuit

/** One line of Circuit's note list. [group] is set for a one-minute part of a longer recording. */
data class ListedNote(val id: Long, val bytes: Long, val epoch: Long, val group: String?)

object NoteListing {
    /** Next to a downloaded part of a longer recording: "<first part's id>,<part>,<1 if last>". */
    const val groupPrefix = "circuit-group-"
    const val momentsPrefix = "circuit-moments-"

    /**
     * Circuit's list of notes waiting: "id,bytes,recorded" per line, and for a part of a longer
     * recording ",first,part,final" after that. Lines that cannot be read are skipped, and a
     * line with a part description that makes no sense is treated as a plain note.
     */
    fun parse(listing: String): List<ListedNote> = listing.lines().filter { it.isNotBlank() }.mapNotNull { line ->
        val f = line.trim().split(',')
        if (f.size < 3) return@mapNotNull null
        val id = f[0].toLongOrNull() ?: return@mapNotNull null
        val bytes = f[1].toLongOrNull() ?: return@mapNotNull null
        val first = f.getOrNull(3)?.toLongOrNull()
        val part = f.getOrNull(4)?.toLongOrNull()
        val last = f.getOrNull(5)?.toIntOrNull()
        val group = if (first != null && first > 0 && part != null && part > 0 && (last == 0 || last == 1)) "$first,$part,$last" else null
        ListedNote(id, bytes, f[2].toLongOrNull() ?: 0L, group)
    }
}
