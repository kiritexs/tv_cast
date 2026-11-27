package com.kiritex.tv_cast

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.net.DatagramSocket

/**
 * The keep-alive's channel on Android: hold starts the foreground service
 * and answers once it is in the foreground or was refused; update re-words
 * its notification; release stops it. The notification's controls come back
 * as play, pause and stop.
 */
class TvCastPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var channel: MethodChannel? = null
    private var network: MethodChannel? = null
    private var context: Context? = null
    private var multicast: WifiManager.MulticastLock? = null
    private val main = Handler(Looper.getMainLooper())
    private val waiting = mutableListOf<MethodChannel.Result>()
    private val onService: (String) -> Unit = { event -> onServiceEvent(event) }
    private val notInTime = Runnable { answerHolds(CastKeepAliveService.EVENT_REFUSED) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        network = MethodChannel(binding.binaryMessenger, NETWORK_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        CastKeepAliveService.listener = onService
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The engine, which serves the TV, is going (the app was swiped
        // away): the service has nothing left to keep.
        context?.let { CastKeepAliveService.stop(it) }
        if (CastKeepAliveService.listener === onService) {
            CastKeepAliveService.listener = null
        }
        answerHolds(CastKeepAliveService.EVENT_REFUSED)
        unlockMulticast()
        channel?.setMethodCallHandler(null)
        channel = null
        network?.setMethodCallHandler(null)
        network = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context ?: return result.success(null)
        when (call.method) {
            "hold" -> hold(context, CastNotice.from(call), result)
            "update" -> {
                CastKeepAliveService.update(context, CastNotice.from(call))
                result.success(null)
            }
            "release" -> {
                CastKeepAliveService.stop(context)
                result.success(null)
            }
            "lockMulticast" -> result.success(lockMulticast(context))
            "unlockMulticast" -> {
                unlockMulticast()
                result.success(null)
            }
            "vpnState" -> Thread {
                // Whatever goes wrong, it answers, and nothing crashes.
                val state = try {
                    vpnState(context)
                } catch (e: Exception) {
                    VPN_NONE
                }
                main.post { result.success(state) }
            }.start()
            else -> result.notImplemented()
        }
    }

    private fun hold(context: Context, notice: CastNotice, result: MethodChannel.Result) {
        if (!CastKeepAliveService.start(context, notice)) {
            return result.success(CastKeepAliveService.EVENT_REFUSED)
        }
        // Answered once the service is in the foreground, or wasn't in time.
        waiting += result
        main.removeCallbacks(notInTime)
        main.postDelayed(notInTime, START_TIMEOUT_MS)
    }

    private fun onServiceEvent(event: String) {
        main.post {
            when (event) {
                CastKeepAliveService.EVENT_HELD,
                CastKeepAliveService.EVENT_REFUSED -> answerHolds(event)
                CastKeepAliveService.ACTION_PLAY,
                CastKeepAliveService.ACTION_PAUSE,
                CastKeepAliveService.ACTION_STOP -> channel?.invokeMethod(event, null)
            }
        }
    }

    /** Held while searching for TVs: see MulticastLock in Dart. */
    private fun lockMulticast(context: Context): Boolean {
        val lock = multicast ?: (context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as? WifiManager)
            ?.createMulticastLock(MULTICAST_TAG)
            ?.also {
                it.setReferenceCounted(false)
                multicast = it
            }
        return try {
            lock?.acquire()
            lock?.isHeld == true
        } catch (e: Exception) {
            false
        }
    }

    private fun unlockMulticast() {
        multicast?.let { if (it.isHeld) it.release() }
    }

    /**
     * Whether a VPN stands between the app and the TVs: "none", "on", or
     * "locked" when it refuses a socket bound to the Wi-Fi around it (a VPN
     * that doesn't allow bypassing). The test socket only binds; nothing is
     * sent.
     */
    private fun vpnState(context: Context): String {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager ?: return VPN_NONE
        val active = cm.activeNetwork ?: return VPN_NONE
        val caps = cm.getNetworkCapabilities(active) ?: return VPN_NONE
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return VPN_NONE
        @Suppress("DEPRECATION")
        val lan = cm.allNetworks.firstOrNull { network ->
            cm.getNetworkCapabilities(network)?.let {
                (it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    it.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) &&
                    !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            } == true
        } ?: return VPN_ON
        return try {
            DatagramSocket().use { lan.bindSocket(it) }
            VPN_ON
        } catch (e: IOException) {
            VPN_LOCKED
        } catch (e: SecurityException) {
            VPN_LOCKED
        }
    }

    private fun answerHolds(answer: String) {
        main.removeCallbacks(notInTime)
        val results = waiting.toList()
        waiting.clear()
        results.forEach { it.success(answer) }
    }

    companion object {
        private const val CHANNEL = "tv_cast/keep_alive"
        private const val NETWORK_CHANNEL = "tv_cast/network"
        private const val MULTICAST_TAG = "tv_cast:search"
        private const val VPN_NONE = "none"
        private const val VPN_ON = "on"
        private const val VPN_LOCKED = "locked"

        // Android gives a started foreground service 5 s to show itself.
        private const val START_TIMEOUT_MS = 6000L
    }
}
