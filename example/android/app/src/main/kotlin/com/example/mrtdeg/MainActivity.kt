package com.example.mrtdeg

import android.graphics.Bitmap
import com.gemalto.jp2.JP2Decoder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "dmrtd/image_decoder"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "decodeJp2k") {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes != null) {
                    Thread {
                        try {
                            val bitmap = JP2Decoder(bytes).decode()
                            if (bitmap != null) {
                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                                val pngBytes = stream.toByteArray()
                                runOnUiThread { result.success(pngBytes) }
                            } else {
                                runOnUiThread { result.error("DECODE_ERROR", "Failed to decode JP2 image to Bitmap", null) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DECODE_EXCEPTION", e.message, null) }
                        }
                    }.start()
                } else {
                    result.error("INVALID_ARGUMENT", "Bytes array is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
