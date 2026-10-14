# ESP-IDF patches

Applied to ESP-IDF automatically by `CMakeLists.txt` (once, idempotent) for every build, local and CI.

## keep-bond-on-transient-failure.patch (ESP-IDF v5.5.3)

The Bluetooth library deletes the stored pairing (in memory and in flash) after any failed LE security
handshake, including a timeout (`SMP_CONN_TOUT`, reason 0x66 in our logs), a busy stack, or a link that
dropped part way. On a weak link that happens in normal use. The phone then still holds its half of the
pairing, the board does not, the next connect fails, Android removes its half too, and the app asks the
person to repair pairing. See Espressif issue #14977 for the same report against `SMP_CONN_TOUT`.

The patch keeps the pairing for failures that are about the link (`SMP_BUSY`, `SMP_ENC_FAIL`,
`SMP_STARTED`, `SMP_RSP_TIMEOUT`, `SMP_FAIL`, `SMP_CONN_TOUT`, `SMP_PAIR_FAIL_UNKNOWN`) and removes it for
everything else, as before. Both places that remove it are changed (`bta_dm_act.c` for the running
security database, `btc_dm.c` for flash); the marker `CIRCUIT_KEEP_BOND_PATCH` shows it is applied.

Moving to another ESP-IDF version: check whether Espressif has fixed this, then regenerate or drop the patch.
