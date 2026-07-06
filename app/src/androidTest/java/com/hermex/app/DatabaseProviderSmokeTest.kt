package com.hermex.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.hermex.app.di.AppModule
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DatabaseProviderSmokeTest {
    @Test
    fun appModuleDatabaseProviderCreatesRoomDatabaseAndDaos() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        val database = AppModule.provideDatabase(appContext)

        assertNotNull(database)
        assertNotNull(database.sessionDao())
        assertNotNull(database.messageDao())
        assertNotNull(database.openHelper.writableDatabase)
    }
}
