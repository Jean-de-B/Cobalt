package com.cobalt.task

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Envoie la commande DFU (0xFD) via BLE UART au bracelet Cobalt.
 *
 * Utilisation depuis Flutter via MethodChannel :
 *   channel.invokeMethod("triggerDfu", {"address": "AA:BB:CC:DD:EE:FF"})
 *
 * À enregistrer dans MainActivity.kt :
 *   BleUartDfuTrigger(context).register(flutterEngine.dartExecutor.binaryMessenger)
 */
class BleUartDfuTrigger(private val context: Context) {

    companion object {
        private const val CHANNEL = "com.cobalt.task/ble_dfu"

        // Nordic UART Service (NUS) — même UUIDs que BleConstants dans Dart
        private val SERVICE_UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val RX_CHAR_UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")

        private const val CMD_ENTER_DFU: Byte = 0xFD.toByte()
    }

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "triggerDfu") {
                val address = call.argument<String>("address")
                if (address.isNullOrEmpty()) {
                    result.error("INVALID_ARG", "Adresse BLE requise", null)
                } else {
                    sendDfuCommand(address, result)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun sendDfuCommand(address: String, result: MethodChannel.Result) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth non disponible", null)
            return
        }

        val device = try {
            adapter.getRemoteDevice(address)
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_ADDR", "Adresse MAC invalide : $address", null)
            return
        }

        var gatt: BluetoothGatt? = null
        var resultSent = false

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    g.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED && !resultSent) {
                    resultSent = true
                    result.error("DISCONNECTED", "Déconnecté avant envoi", null)
                    gatt?.close()
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val rxChar = g.getService(SERVICE_UUID)?.getCharacteristic(RX_CHAR_UUID)
                if (rxChar == null) {
                    if (!resultSent) {
                        resultSent = true
                        result.error("NO_CHAR", "Caractéristique RX introuvable", null)
                    }
                    g.disconnect()
                    return
                }

                rxChar.value = byteArrayOf(CMD_ENTER_DFU)
                @Suppress("DEPRECATION")
                if (Build.VERSION.SDK_INT >= 33) {
                    g.writeCharacteristic(
                        rxChar,
                        byteArrayOf(CMD_ENTER_DFU),
                        BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    )
                } else {
                    rxChar.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    g.writeCharacteristic(rxChar)
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int
            ) {
                if (!resultSent) {
                    resultSent = true
                    if (status == BluetoothGatt.GATT_SUCCESS) {
                        result.success(true)
                    } else {
                        result.error("WRITE_FAIL", "Écriture échouée (status=$status)", null)
                    }
                }
                // Le device va redémarrer → on ferme proprement
                g.disconnect()
                gatt?.close()
            }
        }

        gatt = if (Build.VERSION.SDK_INT >= 23) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }
    }
}
