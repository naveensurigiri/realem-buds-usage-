package com.naveen.realme_buds_tracker

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

// Classic Bluetooth (RFCOMM) bridge. It only opens a connection and passes bytes through.
@Suppress("MissingPermission")
class MainActivity : FlutterActivity() {
    private val uuid: UUID = UUID.fromString("0000079A-D102-11E1-9B23-00025B00A5A5")
    private val ui = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var socket: BluetoothSocket? = null

    private val perms = arrayOf(
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_SCAN,
        )

        private fun hasAllPermissions(): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                perms.all { check_selfPermission(it) == PackageManager.PERMISSION_GRANTED }

        private fun adapter(): BluetoothAdapter? =
        (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "realme_buds/rfcomm")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            if (!hasAllPermissions()) {
                requestPermissions(perms, 1)
                result.error("permission", "Allow the Nearby devices permission, then tap again.", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "bonded" -> {
                    val list = adapter()?.bondedDevices
                        ?.map { mapOf("name" to (it.name ?: ""), "address" to it.address) }
                        ?: emptyList()
                    result.success(list)
                }
                "connect" -> connect(call.argument<String>("address"), result)
                "send" -> {
                    try {
                        val out = socket?.outputStream
                        if (out == null) {
                            result.error("closed", "Not connected", null)
                        } else {
                            out.write(call.arguments as ByteArray)
                            out.flush()
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        result.error("send", e.message ?: "Send failed", null)
                    }
                }
                "disconnect" -> {
                    try { socket?.close() } catch (ignored: Exception) {}
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun connect(address: String?, result: MethodChannel.Result) {
        val bt = adapter()
        if (address == null || bt == null) {
            result.error("args", "No Bluetooth adapter or address", null)
            return
        }
        try { socket?.close() } catch (ignored: Exception) {}
        Thread {
            var local: BluetoothSocket? = null
            var connected = false
            try {
                bt.cancelDiscovery()
                local = bt.getRemoteDevice(address).createRfcommSocketToServiceRecord(uuid)
                local.connect()
                socket = local
                connected = true
                ui.post { result.success(true) }
                val buf = ByteArray(1024)
                val input = local.inputStream
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    val chunk = buf.copyOf(n)
                    ui.post { channel?.invokeMethod("data", chunk) }
                }
            } catch (e: Exception) {
                if (!connected) {
                    val msg = e.message ?: "Connection failed"
                    ui.post { result.error("connect", msg, null) }
                }
            } finally {
                try { local?.close() } catch (ignored: Exception) {}
                if (socket === local) socket = null
                if (connected) ui.post { channel?.invokeMethod("closed", null) }
            }
        }.start()
    }
}
