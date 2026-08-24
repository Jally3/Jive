package com.jive.app.jive

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.os.storage.StorageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val isTelevision: Boolean
        get() =
            resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK ==
                Configuration.UI_MODE_TYPE_TELEVISION

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 电视无方向传感器且面板固定横屏，避免任何页面请求竖屏导致旋转黑边。
        if (isTelevision) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jive/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "isTelevision") {
                    result.success(isTelevision)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jive/cache")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "totalCapacityBytes" -> {
                        try {
                            val stat = StatFs(filesDir.absolutePath)
                            result.success(stat.totalBytes)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "availableBytes" -> {
                        try {
                            val stat = StatFs(filesDir.absolutePath)
                            result.success(stat.availableBytes)
                        } catch (e: Exception) {
                            result.success(0L)
                        }
                    }
                    "platformCacheLimitBytes" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val storageManager =
                                    getSystemService(STORAGE_SERVICE) as StorageManager
                                val uuid = storageManager.primaryStorageVolume
                                    .uuid
                                    ?.let { java.util.UUID.fromString(it) }
                                result.success(
                                    if (uuid != null) {
                                        storageManager.getCacheQuotaBytes(uuid)
                                    } else {
                                        null
                                    },
                                )
                            } catch (e: Exception) {
                                result.success(null)
                            }
                        } else {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
