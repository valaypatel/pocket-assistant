package com.valay.circuit.short_circuit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BoardBatteryTest {
    @Test
    fun readsTheChargeFromABoardStatus() {
        val status = "@sync-status\nwaiting=2\nreset=1\nuptime=90\nfree_min=1\nstack_min=2\nstops=0\nbat=40"
        assertEquals(40, BoardBattery.percentIn(status))
    }

    @Test
    fun ignoresStatusWithoutAReading() {
        assertNull(BoardBattery.percentIn("@sync-status\nwaiting=2\nreset=1\nuptime=90"))
        assertNull(BoardBattery.percentIn("@sync-status\nbat=-1"))
        assertNull(BoardBattery.percentIn("@sync-status\nbat=abc"))
        assertNull(BoardBattery.percentIn("@sync-status\nbat=140"))
    }

    @Test
    fun alertsOncePerDipAndRearmsWhenCharged() {
        assertEquals(BoardBattery.Action.Alert, BoardBattery.decide(15, warned = false))
        assertEquals(BoardBattery.Action.Nothing, BoardBattery.decide(10, warned = true))
        // between the two thresholds nothing changes, so a wobbling reading cannot alert twice
        assertEquals(BoardBattery.Action.Nothing, BoardBattery.decide(20, warned = true))
        assertEquals(BoardBattery.Action.Nothing, BoardBattery.decide(20, warned = false))
        assertEquals(BoardBattery.Action.Rearm, BoardBattery.decide(25, warned = true))
        assertEquals(BoardBattery.Action.Nothing, BoardBattery.decide(80, warned = false))
    }
}
