package com.valay.circuit.short_circuit

import android.Manifest
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.regex.Pattern

/**
 * Puts the Record widget on the home screen of a clean device and taps it like a person would,
 * then reports which of the two designed outcomes Android allowed on this version:
 *  - RECORDING_IN_PLACE: the widget started the recording without opening the app, or
 *  - APP_OPENED: the fallback, the app opened and starts recording itself.
 * Either passes. Nothing happening, or no widget to tap, fails.
 */
class RecordWidgetTest {
    private val tag = "WIDGET_TEST"
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val appPackage = context.packageName

    @Before
    fun setUp() {
        instrumentation.uiAutomation.grantRuntimePermission(appPackage, Manifest.permission.RECORD_AUDIO)
        runCatching {
            instrumentation.uiAutomation.grantRuntimePermission(appPackage, Manifest.permission.POST_NOTIFICATIONS)
        }
        // What the app does on first start: hand the phone's key to the widget's copy.
        PhoneKeyStore.save(context, 1, ByteArray(32) { it.toByte() })
        device.pressHome()
        device.waitForIdle()
    }

    private fun placeWidget(): UiObject2? {
        val manager = AppWidgetManager.getInstance(context)
        val provider = ComponentName(context, RecordWidgetProvider::class.java)
        Log.i(tag, "pin supported=${manager.isRequestPinAppWidgetSupported} sdk=${android.os.Build.VERSION.SDK_INT}")
        if (manager.isRequestPinAppWidgetSupported) manager.requestPinAppWidget(provider, null, null)
        // The pin dialog shows a preview that also says "Record a note", so press its button
        // first (its label and clickable flag differ between Android versions) and wait until
        // the dialog is gone before looking for the widget on the home screen.
        val addButton = Pattern.compile("add( automatically| to home screen)?", Pattern.CASE_INSENSITIVE)
        val button = device.wait(Until.findObject(By.clazz("android.widget.Button").text(addButton)), 6000)
        val pressed = button != null
        if (button != null) {
            Log.i(tag, "pressing '${button.text}'")
            button.click()
        }
        if (pressed) device.waitForIdle()
        else Log.e(tag, "no add button found; screen: " + device.findObjects(By.pkg(device.currentPackageName)).take(40)
            .joinToString { "${it.className}:${it.text ?: it.contentDescription}" })
        device.wait(Until.gone(By.text("Cancel")), 6000)
        device.wait(Until.findObject(By.text("Record a note")), 10000)?.let { return it }
        // Some launchers (Samsung One UI) put a new widget on another home page when the current one
        // is full. Look through the pages, a swipe at a time, before giving up.
        repeat(4) { page ->
            device.swipe(device.displayWidth * 9 / 10, device.displayHeight / 2, device.displayWidth / 10, device.displayHeight / 2, 20)
            device.waitForIdle()
            Log.i(tag, "looking on home page ${page + 2}")
            device.wait(Until.findObject(By.text("Record a note")), 2500)?.let { return it }
        }
        return null
    }

    private fun dumpScreen(why: String) {
        Log.e(tag, "$why; windows: " + device.findObjects(By.pkg(device.currentPackageName)).take(30)
            .joinToString { "${it.className}:${it.text ?: it.contentDescription}" })
    }

    @Test
    fun tapRecordsOrOpensTheApp() {
        val widget = placeWidget()
        if (widget == null) {
            dumpScreen("widget not found on home screen")
        }
        assertNotNull("Record widget did not appear on the home screen", widget)
        Log.i(tag, "widget on screen; launcher=${device.currentPackageName}")

        widget!!.click()
        val outcome = when {
            device.wait(Until.hasObject(By.text("Recording")), 8000) -> "RECORDING_IN_PLACE"
            device.wait(Until.hasObject(By.pkg(appPackage)), 6000) -> "APP_OPENED"
            else -> "NOTHING_HAPPENED"
        }
        Log.i(tag, "OUTCOME=$outcome foreground=${device.currentPackageName}")
        assertTrue("Tap did nothing (outcome=$outcome)", outcome != "NOTHING_HAPPENED")

        if (outcome == "RECORDING_IN_PLACE") {
            val pause = device.findObject(By.desc("Pause the recording"))
            assertNotNull("Pause button missing while recording", pause)
            pause.click()
            assertTrue("Widget did not show Paused", device.wait(Until.hasObject(By.text("Paused")), 5000))
            device.findObject(By.desc("Resume the recording"))?.click()
            assertTrue("Widget did not resume", device.wait(Until.hasObject(By.text("Recording")), 5000))
            val stop = device.findObject(By.desc("Stop and save the recording"))
            assertNotNull("Stop button missing", stop)
            stop.click()
            assertTrue("Widget did not return to idle", device.wait(Until.hasObject(By.text("Record a note")), 8000))
            Log.i(tag, "PAUSE_RESUME_STOP=OK")
        }
    }
}
