#!/usr/bin/env python3
"""근무 캘린더 앱 설치 스크립트.

이 폴더(shift_calendar)에서 `python3 setup.py` 를 실행하면
  1) 안드로이드용 Flutter 프로젝트(app/)를 만들고
  2) lib/main.dart, pubspec.yaml 을 복사하고
  3) 알람에 필요한 권한/설정을 자동으로 패치하고
  4) flutter pub get 까지 실행합니다.
"""
import math
import re
import shutil
import struct
import wave
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE / "app"


def run(cmd, cwd=None):
    print("$", " ".join(cmd))
    r = subprocess.run(cmd, cwd=cwd)
    if r.returncode != 0:
        sys.exit(f"실패: {' '.join(cmd)}")


if shutil.which("flutter") is None:
    sys.exit("flutter 명령을 찾을 수 없습니다. 먼저 Flutter SDK를 설치하세요. (README 참고)")

# 1) 프로젝트 생성
if not APP.exists():
    run(["flutter", "create", "--project-name", "shift_calendar",
         "--org", "com.myshift", "--platforms", "android,web", str(APP)])

# 이미 android 만으로 만든 app 폴더가 있으면 web(크롬 미리보기)도 추가
if not (APP / "web").exists():
    run(["flutter", "create", "--platforms", "web", "."], cwd=APP)

# 2) 소스 복사
shutil.copy(HERE / "pubspec.yaml", APP / "pubspec.yaml")
(APP / "lib").mkdir(exist_ok=True)
for f in (HERE / "lib").glob("*.dart"):
    shutil.copy(f, APP / "lib" / f.name)
test_dir = APP / "test"
if test_dir.exists():  # 기본 템플릿 테스트는 우리 앱과 맞지 않으므로 제거
    shutil.rmtree(test_dir)

# 3-a) AndroidManifest 패치
manifest = APP / "android/app/src/main/AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")

# 구글 캘린더/테스크 동기화에 인터넷 권한 필요 (release 빌드의 main 매니페스트에는 기본으로 없음)
if "android.permission.INTERNET" not in text:
    text = text.replace(
        "<application",
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
        1,
    )

if "SCHEDULE_EXACT_ALARM" not in text:
    perms ="""    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
"""
    text = text.replace("<application", perms + "    <application", 1)

for perm in ("READ_CALENDAR", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
             "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_MEDIA_PLAYBACK"):
    if f'android.permission.{perm}"' not in text:
        text = text.replace(
            "<application",
            f'<uses-permission android:name="android.permission.{perm}"/>\n    <application',
            1,
        )

if "ScheduledNotificationReceiver" not in text:
    receivers = """        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver" />
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
"""
    text = text.replace("</application>", receivers + "    </application>", 1)

# 근무 알람 전용 화면/서비스/수신기 (알람 시계 방식)
_acts = list((APP / "android/app/src/main").glob("**/MainActivity.*"))
_m = re.search(r"package\s+([\w.]+)", _acts[0].read_text(encoding="utf-8")) if _acts else None
PKG = _m.group(1) if _m else "com.myshift.shift_calendar"
if "AlarmService" not in text:
    comps = f"""        <activity android:name="{PKG}.AlarmActivity"
            android:exported="false"
            android:showWhenLocked="true"
            android:turnScreenOn="true"
            android:launchMode="singleTask"
            android:taskAffinity="{PKG}.alarm"
            android:excludeFromRecents="true"
            android:theme="@android:style/Theme.DeviceDefault.NoActionBar" />
        <service android:name="{PKG}.AlarmService"
            android:exported="false"
            android:foregroundServiceType="mediaPlayback" />
        <receiver android:name="{PKG}.AlarmReceiver" android:exported="false">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
"""
    text = text.replace("</application>", comps + "    </application>", 1)

# 앱 이름을 한글로
text = re.sub(r'android:label="[^"]*"', 'android:label="근무 캘린더"', text, count=1)
manifest.write_text(text, encoding="utf-8")

# 3-b) Gradle 패치 (core library desugaring: flutter_local_notifications 필수)
gradle_kts = APP / "android/app/build.gradle.kts"
gradle_groovy = APP / "android/app/build.gradle"

# 고정 서명 키: 매번 같은 키로 서명해야 폰에서 데이터 유지한 채 업데이트(덮어쓰기)가 됨
KEYSTORE = HERE / "release.keystore"
if KEYSTORE.exists():
    shutil.copy(KEYSTORE, APP / "android/app/release.keystore")
else:
    print("경고: release.keystore 가 없어 서명이 매번 달라집니다. 폰에서 업데이트 시 기존 앱을 지워야 합니다.")

if gradle_kts.exists():
    g = gradle_kts.read_text(encoding="utf-8")
    if "isCoreLibraryDesugaringEnabled" not in g:
        g = g.replace("compileOptions {",
                      "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
    if "coreLibraryDesugaring(" not in g:
        g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
    if KEYSTORE.exists() and "release.keystore" not in g:
        g = g.replace("buildTypes {", '''signingConfigs {
        create("release") {
            storeFile = file("release.keystore")
            storeType = "pkcs12"
            storePassword = "shiftcal123"
            keyAlias = "shift"
            keyPassword = "shiftcal123"
        }
    }

    buildTypes {''', 1)
        g = g.replace('signingConfigs.getByName("debug")', 'signingConfigs.getByName("release")')
    gradle_kts.write_text(g, encoding="utf-8")
elif gradle_groovy.exists():
    g = gradle_groovy.read_text(encoding="utf-8")
    if "coreLibraryDesugaringEnabled" not in g:
        g = g.replace("compileOptions {",
                      "compileOptions {\n        coreLibraryDesugaringEnabled true", 1)
    if "coreLibraryDesugaring '" not in g:
        g += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
    if KEYSTORE.exists() and "release.keystore" not in g:
        g = g.replace("buildTypes {", '''signingConfigs {
        release {
            storeFile file("release.keystore")
            storeType "pkcs12"
            storePassword "shiftcal123"
            keyAlias "shift"
            keyPassword "shiftcal123"
        }
    }

    buildTypes {''', 1)
        g = g.replace("signingConfigs.debug", "signingConfigs.release")
    gradle_groovy.write_text(g, encoding="utf-8")
else:
    print("경고: android/app/build.gradle(.kts) 를 찾지 못했습니다. README의 수동 설정을 따라주세요.")


# 3-b2) 릴리스 빌드에서 알림 플러그인(Gson)이 깨지지 않도록 보호 규칙
(APP / "android/app/proguard-rules.pro").write_text(
    "-keep class com.dexterous.** { *; }\n"
    "-keep class com.google.gson.reflect.TypeToken { *; }\n"
    "-keep class * extends com.google.gson.reflect.TypeToken\n"
    "-keepattributes Signature\n"
    "-keepattributes *Annotation*\n",
    encoding="utf-8",
)

# 3-c) 알람음(벨/삐삐/멜로디/차임)을 직접 만들어 안드로이드 raw 리소스로 넣는다 (별도 파일 업로드 불필요)
def _write_wav(path, samples, rate=22050):
    peak = max(1e-9, max(abs(x) for x in samples))
    scale = 0.9 * 32767 / peak
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(x * scale)) for x in samples))


def _note(freq, dur, rate=22050, harm=((1, 1.0), (2, 0.35), (3, 0.15)), decay=6.0, attack=0.004):
    n = int(rate * dur)
    out = []
    for i in range(n):
        t = i / rate
        env = (1 - math.exp(-t / attack)) * math.exp(-decay * t)
        v = sum(a * math.sin(2 * math.pi * freq * h * t) for h, a in harm)
        out.append(v * env)
    return out


def _silence(dur, rate=22050):
    return [0.0] * int(rate * dur)


def _mix(parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


def make_tones(raw_dir):
    raw_dir.mkdir(parents=True, exist_ok=True)
    # 벨: 높은 종소리 3번
    bell = []
    for _ in range(3):
        bell += _note(988, 0.55, harm=((1, 1.0), (2.76, 0.5), (5.4, 0.25)), decay=4.5)
    bell += _silence(0.7)
    _write_wav(raw_dir / "alarm_bell.wav", bell)
    # 삐삐삐: 디지털 알람
    beep = []
    for _ in range(4):
        beep += _note(1400, 0.12, harm=((1, 1.0), (3, 0.3)), decay=0.5)
        beep += _silence(0.1)
    beep += _silence(0.6)
    _write_wav(raw_dir / "alarm_beep.wav", beep)
    # 멜로디: 도 미 솔 높은도
    mel = []
    for f in (523, 659, 784, 1047, 784, 659):
        mel += _note(f, 0.24, harm=((1, 1.0), (2, 0.25)), decay=3.0)
    mel += _silence(0.7)
    _write_wav(raw_dir / "alarm_melody.wav", mel)
    # 차임: 부드러운 두 음
    soft = _note(660, 0.9, harm=((1, 1.0), (2, 0.2)), decay=2.5)
    soft += _note(880, 1.1, harm=((1, 1.0), (2, 0.2)), decay=2.5)
    soft += _silence(1.0)
    _write_wav(raw_dir / "alarm_soft.wav", soft)
    # 안드로이드가 쓰지 않는 리소스로 알고 지우지 않도록 보호
    (raw_dir / "keep.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources xmlns:tools="http://schemas.android.com/tools"\n'
        '    tools:keep="@raw/alarm_*" />\n',
        encoding="utf-8",
    )


make_tones(APP / "android/app/src/main/res/raw")

# 3-d) MainActivity: 알람 볼륨 조절 / 설정 화면 열기 기능
KOTLIN = """package PKGNAME

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.CalendarContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

@SuppressLint("MissingPermission", "NewApi", "BatteryLife")
class MainActivity : FlutterActivity() {
    private var pendingPerm: MethodChannel.Result? = null
    private val calPermCode = 7001

    private fun hasCal(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED
    }

    private fun calendars(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val proj = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR
        )
        val c = contentResolver.query(CalendarContract.Calendars.CONTENT_URI, proj, null, null, null)
        if (c != null) {
            try {
                while (c.moveToNext()) {
                    out.add(
                        mapOf(
                            "id" to c.getLong(0),
                            "name" to (c.getString(1) ?: ""),
                            "account" to (c.getString(2) ?: ""),
                            "color" to c.getInt(3)
                        )
                    )
                }
            } finally {
                c.close()
            }
        }
        return out
    }

    private fun events(startMs: Long, endMs: Long, ids: List<Long>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val b = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(b, startMs)
        ContentUris.appendId(b, endMs)
        val proj = arrayOf(
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_ID
        )
        var sel: String? = null
        if (ids.isNotEmpty()) {
            sel = CalendarContract.Instances.CALENDAR_ID + " IN (" + ids.joinToString(",") + ")"
        }
        val c = contentResolver.query(
            b.build(), proj, sel, null, CalendarContract.Instances.BEGIN + " ASC"
        )
        if (c != null) {
            try {
                while (c.moveToNext()) {
                    out.add(
                        mapOf(
                            "title" to (c.getString(0) ?: ""),
                            "begin" to c.getLong(1),
                            "end" to c.getLong(2),
                            "allDay" to (c.getInt(3) == 1),
                            "calId" to c.getLong(4)
                        )
                    )
                }
            } finally {
                c.close()
            }
        }
        return out
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == calPermCode) {
            val ok = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPerm?.success(ok)
            pendingPerm = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiftcal/native")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getAlarmVolume" -> {
                            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            result.success(
                                listOf(
                                    am.getStreamVolume(AudioManager.STREAM_ALARM),
                                    am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                                )
                            )
                        }
                        "setAlarmVolume" -> {
                            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                            val v = call.argument<Int>("v") ?: 0
                            am.setStreamVolume(AudioManager.STREAM_ALARM, v, 0)
                            result.success(true)
                        }
                        "openAppSettings" -> {
                            val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            i.data = Uri.parse("package:" + packageName)
                            startActivity(i)
                            result.success(true)
                        }
                        "openBatterySettings" -> {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            result.success(true)
                        }
                        "openNotificationSettings" -> {
                            val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            i.putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            startActivity(i)
                            result.success(true)
                        }
                        "isIgnoringBattery" -> {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            val ok = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                                pm.isIgnoringBatteryOptimizations(packageName)
                            result.success(ok)
                        }
                        "requestIgnoreBattery" -> {
                            val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            i.data = Uri.parse("package:" + packageName)
                            startActivity(i)
                            result.success(true)
                        }
                        "getFilesDir" -> result.success(filesDir.absolutePath)
                        "hasCalendarPermission" -> result.success(hasCal())
                        "requestCalendarPermission" -> {
                            if (hasCal()) {
                                result.success(true)
                            } else {
                                pendingPerm = result
                                requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), calPermCode)
                            }
                        }
                        "getCalendars" -> {
                            if (hasCal()) result.success(calendars()) else result.success(emptyList<Any>())
                        }
                        "getEvents" -> {
                            val s = call.argument<Number>("start")?.toLong() ?: 0L
                            val e = call.argument<Number>("end")?.toLong() ?: 0L
                            val raw = call.argument<List<Any>>("ids") ?: emptyList<Any>()
                            val ids = raw.map { (it as Number).toLong() }
                            if (hasCal()) result.success(events(s, e, ids)) else result.success(emptyList<Any>())
                        }
                        "alarmSetAll" -> {
                            val raw = call.argument<List<Map<String, Any?>>>("alarms") ?: emptyList()
                            val arr = JSONArray()
                            for (m in raw) arr.put(JSONObject(m))
                            result.success(AlarmKit.setAll(this, arr))
                        }
                        "alarmScheduleOne" -> {
                            val m = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                            val o = JSONObject(m)
                            AlarmKit.lastError = ""
                            val r = AlarmKit.scheduleOne(this, o)
                            AlarmKit.upsert(this, o)
                            result.success(if (AlarmKit.lastError.isEmpty()) r else r + " / " + AlarmKit.lastError)
                        }
                        "alarmRingNow" -> {
                            val m = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                            AlarmKit.startRing(this, JSONObject(m))
                            result.success(true)
                        }
                        "alarmTakeSkipped" -> result.success(AlarmKit.takeSkipped(this))
                        "alarmInfo" -> result.success(AlarmKit.info(this))
                        "canFullScreen" -> result.success(AlarmKit.canFullScreen(this))
                        "openFullScreenSettings" -> {
                            startActivity(AlarmKit.fullScreenSettings(this))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("native", e.message, null)
                }
            }
    }
}
"""

ALARMKIT = r'''package PKGNAME

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// 근무 알람을 안드로이드 "알람 시계"처럼 직접 울리는 부분
// - AlarmManager.setAlarmClock 으로 예약
// - 시간이 되면 AlarmService 가 알람 소리(알람 볼륨, 진동/무음 모드에서도 울림)와 진동을 켜고
// - 잠금 화면 위에 AlarmActivity(5분 / 10분 / 알람 종료)를 띄운다

@SuppressLint("NewApi", "MissingPermission")
object AlarmKit {
    const val SNOOZE_BASE = 0x40000000
    const val RING_NOTIF = 0x3FFFFF01
    const val CH_RING = "ring_screen_v1"
    const val CH_NOTICE = "ring_notice_v1"
    const val CH_FALLBACK = "ring_fallback_v1"
    const val A_RING = "shiftcal.RING"
    const val A_NOTICE = "shiftcal.NOTICE"
    const val A_SKIP = "shiftcal.SKIP"
    const val A_SNOOZE = "shiftcal.SNOOZE"
    const val A_STOP = "shiftcal.STOP"

    var lastError: String = ""

    private fun prefs(c: Context) = c.getSharedPreferences("shiftcal_alarms", Context.MODE_PRIVATE)

    fun load(c: Context): JSONArray {
        return try {
            JSONArray(prefs(c).getString("list", "[]") ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }
    }

    fun save(c: Context, a: JSONArray) {
        prefs(c).edit().putString("list", a.toString()).commit()
    }

    private fun immutable(): Int = PendingIntent.FLAG_IMMUTABLE

    fun bcast(c: Context, action: String, req: Int, o: JSONObject?, min: Int = 0): PendingIntent {
        val i = Intent(c, AlarmReceiver::class.java)
        i.action = action
        i.putExtra("id", o?.optInt("id", req) ?: req)
        if (o != null) i.putExtra("json", o.toString())
        i.putExtra("min", min)
        return PendingIntent.getBroadcast(c, req, i, PendingIntent.FLAG_UPDATE_CURRENT or immutable())
    }

    fun launch(c: Context): PendingIntent {
        val li = c.packageManager.getLaunchIntentForPackage(c.packageName)
            ?: Intent(c, MainActivity::class.java)
        return PendingIntent.getActivity(c, 0, li, PendingIntent.FLAG_UPDATE_CURRENT or immutable())
    }

    fun canExact(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    fun noticeId(id: Int): Int = 0x20000000 or (id and 0x0FFFFFFF)

    // 하나 예약. 반환: clock / inexact / fail / past
    fun scheduleOne(c: Context, o: JSONObject): String {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val id = o.optInt("id")
        val at = o.optLong("at")
        val now = System.currentTimeMillis()
        if (at <= now) return "past"
        val ring = bcast(c, A_RING, id, o)
        var r = "fail"
        try {
            if (!canExact(c)) throw SecurityException("정확한 알람 권한 없음")
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, launch(c)), ring)
            r = "clock"
        } catch (e: Exception) {
            lastError = e.toString()
            try {
                if (Build.VERSION.SDK_INT >= 23) {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, ring)
                } else {
                    am.set(AlarmManager.RTC_WAKEUP, at, ring)
                }
                r = "inexact"
            } catch (e2: Exception) {
                lastError = e2.toString()
            }
        }
        val nt = o.optLong("noticeAt", 0L)
        if (nt > now) {
            val np = bcast(c, A_NOTICE, id, o)
            try {
                if (Build.VERSION.SDK_INT >= 23 && canExact(c)) {
                    am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, nt, np)
                } else if (Build.VERSION.SDK_INT >= 23) {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, nt, np)
                } else {
                    am.set(AlarmManager.RTC_WAKEUP, nt, np)
                }
            } catch (e: Exception) {
                lastError = e.toString()
            }
        }
        return r
    }

    fun cancelOne(c: Context, id: Int) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            val a = bcast(c, A_RING, id, null)
            am.cancel(a)
            a.cancel()
            val b = bcast(c, A_NOTICE, id, null)
            am.cancel(b)
            b.cancel()
        } catch (e: Exception) {
            lastError = e.toString()
        }
    }

    // 앱이 계산한 근무 알람 목록으로 통째로 바꾼다 (다시 울림/테스트 알람은 유지)
    fun setAll(c: Context, arr: JSONArray): Map<String, Any> {
        lastError = ""
        val now = System.currentTimeMillis()
        val old = load(c)
        val newIds = HashSet<Int>()
        for (k in 0 until arr.length()) {
            val o = arr.optJSONObject(k) ?: continue
            newIds.add(o.optInt("id"))
        }
        val keep = JSONArray()
        for (k in 0 until old.length()) {
            val o = old.optJSONObject(k) ?: continue
            val id = o.optInt("id")
            if (id >= SNOOZE_BASE || id == 9002) {
                if (o.optLong("at") > now) keep.put(o)
                continue
            }
            if (!newIds.contains(id)) cancelOne(c, id)
        }
        var clock = 0
        var inexact = 0
        var fail = 0
        for (k in 0 until arr.length()) {
            val o = arr.optJSONObject(k) ?: continue
            when (scheduleOne(c, o)) {
                "clock" -> clock++
                "inexact" -> inexact++
                "fail" -> fail++
                else -> continue
            }
            keep.put(o)
        }
        save(c, keep)
        return mapOf(
            "clock" to clock,
            "inexact" to inexact,
            "fail" to fail,
            "total" to keep.length(),
            "error" to lastError
        )
    }

    fun upsert(c: Context, o: JSONObject) {
        val id = o.optInt("id")
        val old = load(c)
        val out = JSONArray()
        for (k in 0 until old.length()) {
            val x = old.optJSONObject(k) ?: continue
            if (x.optInt("id") != id) out.put(x)
        }
        out.put(o)
        save(c, out)
    }

    fun remove(c: Context, id: Int) {
        val old = load(c)
        val out = JSONArray()
        for (k in 0 until old.length()) {
            val x = old.optJSONObject(k) ?: continue
            if (x.optInt("id") != id) out.put(x)
        }
        save(c, out)
    }

    // 재부팅/앱 업데이트 후 다시 예약
    fun restore(c: Context) {
        val now = System.currentTimeMillis()
        val old = load(c)
        val out = JSONArray()
        for (k in 0 until old.length()) {
            val o = old.optJSONObject(k) ?: continue
            if (o.optLong("at") <= now) continue
            scheduleOne(c, o)
            out.put(o)
        }
        save(c, out)
    }

    fun info(c: Context): Map<String, Any> {
        val now = System.currentTimeMillis()
        val l = load(c)
        var n = 0
        var next = 0L
        for (k in 0 until l.length()) {
            val o = l.optJSONObject(k) ?: continue
            val at = o.optLong("at")
            if (at <= now) continue
            n++
            if (next == 0L || at < next) next = at
        }
        return mapOf("count" to n, "next" to next)
    }

    fun addSkipped(c: Context, key: String) {
        if (key.isEmpty()) return
        val p = prefs(c)
        val a = try {
            JSONArray(p.getString("skipped", "[]") ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }
        a.put(key)
        p.edit().putString("skipped", a.toString()).commit()
    }

    fun takeSkipped(c: Context): List<String> {
        val p = prefs(c)
        val out = ArrayList<String>()
        try {
            val a = JSONArray(p.getString("skipped", "[]") ?: "[]")
            for (k in 0 until a.length()) out.add(a.optString(k))
        } catch (e: Exception) {
        }
        p.edit().putString("skipped", "[]").commit()
        return out
    }

    fun ensureChannels(c: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = c.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CH_RING) == null) {
            val ch = NotificationChannel(CH_RING, "알람 화면", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "근무 알람이 울릴 때 화면을 띄웁니다 (소리는 앱이 직접 냄)"
            ch.setSound(null, null)
            ch.enableVibration(false)
            ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            ch.setBypassDnd(true)
            nm.createNotificationChannel(ch)
        }
        if (nm.getNotificationChannel(CH_NOTICE) == null) {
            val ch = NotificationChannel(CH_NOTICE, "알람 미리 알림", NotificationManager.IMPORTANCE_LOW)
            ch.description = "알람이 울리기 전 N분 뒤 알람 표시"
            nm.createNotificationChannel(ch)
        }
        if (nm.getNotificationChannel(CH_FALLBACK) == null) {
            val ch = NotificationChannel(CH_FALLBACK, "알람 (예비)", NotificationManager.IMPORTANCE_HIGH)
            ch.setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
            )
            ch.enableVibration(true)
            ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            ch.setBypassDnd(true)
            nm.createNotificationChannel(ch)
        }
    }

    @Suppress("DEPRECATION")
    fun builder(c: Context, ch: String): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, ch) else Notification.Builder(c)
    }

    @Suppress("DEPRECATION")
    fun action(title: String, pi: PendingIntent): Notification.Action {
        return Notification.Action.Builder(0, title, pi).build()
    }

    fun postNotice(c: Context, o: JSONObject) {
        ensureChannels(c)
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val id = o.optInt("id")
        val at = o.optLong("at")
        val left = at - System.currentTimeMillis()
        if (left <= 0) return
        val b = builder(c, CH_NOTICE)
            .setSmallIcon(c.applicationInfo.icon)
            .setContentTitle(o.optString("noticeTitle", "곧 알람이 울려요"))
            .setContentText(o.optString("noticeBody", ""))
            .setWhen(at)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(launch(c))
            .addAction(action("이번 알람 끄기", bcast(c, A_SKIP, id, o)))
        if (Build.VERSION.SDK_INT >= 24) b.setChronometerCountDown(true)
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(left)
        nm.notify(noticeId(id), b.build())
    }

    fun skip(c: Context, id: Int, key: String) {
        cancelOne(c, id)
        remove(c, id)
        addSkipped(c, key)
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(noticeId(id))
        try {
            Toast.makeText(c, "이번 알람을 껐어요", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
        }
    }

    fun snooze(c: Context, src: JSONObject?, min: Int) {
        if (src == null) return
        val n = JSONObject(src.toString())
        val baseId = src.optInt("id")
        n.put("id", SNOOZE_BASE + (baseId and 0xFFFFFF))
        n.put("at", System.currentTimeMillis() + min * 60000L)
        n.put("noticeAt", 0L)
        val body = src.optString("body", "")
        if (!body.endsWith("(다시 울림)")) n.put("body", "$body (다시 울림)")
        scheduleOne(c, n)
        upsert(c, n)
        try {
            Toast.makeText(c, "${min}분 후에 다시 울려요", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
        }
    }

    fun activityIntent(c: Context, o: JSONObject): Intent {
        val i = Intent(c, AlarmActivity::class.java)
        i.putExtra("json", o.toString())
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION)
        return i
    }

    @Suppress("DEPRECATION")
    fun ringNotification(c: Context, o: JSONObject, channel: String): Notification {
        val full = PendingIntent.getActivity(
            c, 1, activityIntent(c, o), PendingIntent.FLAG_UPDATE_CURRENT or immutable()
        )
        val b = builder(c, channel)
            .setSmallIcon(c.applicationInfo.icon)
            .setContentTitle(o.optString("title", "알람"))
            .setContentText(o.optString("body", ""))
            .setCategory(Notification.CATEGORY_ALARM)
            .setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(true)
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .addAction(action("5분 후 다시 울림", bcast(c, A_SNOOZE, 5, o, 5)))
            .addAction(action("10분 후 다시 울림", bcast(c, A_SNOOZE, 10, o, 10)))
            .addAction(action("알람 종료", bcast(c, A_STOP, 3, o)))
        return b.build()
    }

    // 서비스를 못 띄우는 경우를 위한 예비: 알람 채널 알림 (소리는 채널 설정을 따름)
    fun fallbackNotify(c: Context, o: JSONObject) {
        try {
            ensureChannels(c)
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(RING_NOTIF, ringNotification(c, o, CH_FALLBACK))
        } catch (e: Exception) {
            lastError = e.toString()
        }
    }

    fun startRing(c: Context, o: JSONObject) {
        val si = Intent(c, AlarmService::class.java)
        si.putExtra("json", o.toString())
        try {
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(si) else c.startService(si)
        } catch (e: Exception) {
            lastError = e.toString()
            fallbackNotify(c, o)
        }
    }

    fun stopRing(c: Context) {
        try {
            c.stopService(Intent(c, AlarmService::class.java))
        } catch (e: Exception) {
        }
        try {
            val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(RING_NOTIF)
        } catch (e: Exception) {
        }
        try {
            AlarmActivity.current?.finish()
        } catch (e: Exception) {
        }
    }

    fun canFullScreen(c: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    fun fullScreenSettings(c: Context): Intent {
        if (Build.VERSION.SDK_INT >= 34) {
            val i = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
            i.data = Uri.parse("package:" + c.packageName)
            return i
        }
        val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        i.data = Uri.parse("package:" + c.packageName)
        return i
    }
}

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val o = try {
            JSONObject(intent.getStringExtra("json") ?: "{}")
        } catch (e: Exception) {
            JSONObject()
        }
        val id = intent.getIntExtra("id", o.optInt("id"))
        when (intent.action) {
            AlarmKit.A_RING -> {
                AlarmKit.remove(context, id)
                AlarmKit.startRing(context, o)
            }
            AlarmKit.A_NOTICE -> AlarmKit.postNotice(context, o)
            AlarmKit.A_SKIP -> AlarmKit.skip(context, id, o.optString("key", ""))
            AlarmKit.A_SNOOZE -> {
                AlarmKit.snooze(context, o, intent.getIntExtra("min", 5))
                AlarmKit.stopRing(context)
            }
            AlarmKit.A_STOP -> AlarmKit.stopRing(context)
            else -> AlarmKit.restore(context)
        }
    }
}

@SuppressLint("NewApi", "WakelockTimeout")
class AlarmService : Service() {
    private var player: MediaPlayer? = null
    private var vib: Vibrator? = null
    private var wl: PowerManager.WakeLock? = null
    private val h = Handler(Looper.getMainLooper())
    private val timeout = Runnable { AlarmKit.stopRing(this) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val o = try {
            JSONObject(intent?.getStringExtra("json") ?: "{}")
        } catch (e: Exception) {
            JSONObject()
        }
        AlarmKit.ensureChannels(this)
        val n = AlarmKit.ringNotification(this, o, AlarmKit.CH_RING)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(AlarmKit.RING_NOTIF, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(AlarmKit.RING_NOTIF, n)
            }
        } catch (e: Exception) {
            AlarmKit.lastError = e.toString()
            AlarmKit.fallbackNotify(this, o)
            stopSelf()
            return START_NOT_STICKY
        }
        stopSound()
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val w = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "shiftcal:alarm")
            w.acquire(6 * 60 * 1000L)
            wl = w
        } catch (e: Exception) {
        }
        if (o.optBoolean("sound", true)) playSound(o.optString("tone", "bell"))
        if (o.optBoolean("vibrate", true)) startVib()
        h.removeCallbacks(timeout)
        h.postDelayed(timeout, 5 * 60 * 1000L)
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(AlarmKit.noticeId(o.optInt("id")))
        } catch (e: Exception) {
        }
        try {
            startActivity(AlarmKit.activityIntent(this, o))
        } catch (e: Exception) {
        }
        return START_NOT_STICKY
    }

    private fun startPlayer(uri: Uri) {
        val mp = MediaPlayer()
        mp.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
        )
        mp.setDataSource(this, uri)
        mp.isLooping = true
        mp.prepare()
        mp.start()
        player = mp
    }

    @SuppressLint("DiscouragedApi")
    private fun playSound(tone: String) {
        val resId = if (tone == "sys") 0 else resources.getIdentifier("alarm_$tone", "raw", packageName)
        val sys = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        val uri = if (resId != 0) Uri.parse("android.resource://$packageName/$resId") else sys
        try {
            startPlayer(uri)
        } catch (e: Exception) {
            AlarmKit.lastError = e.toString()
            try {
                stopSound()
                startPlayer(Settings.System.DEFAULT_ALARM_ALERT_URI)
            } catch (e2: Exception) {
                AlarmKit.lastError = e2.toString()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun startVib() {
        try {
            val v: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            val pat = longArrayOf(0, 800, 500, 800, 500)
            if (Build.VERSION.SDK_INT >= 26) {
                v?.vibrate(
                    VibrationEffect.createWaveform(pat, 0),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
                )
            } else {
                v?.vibrate(pat, 0)
            }
            vib = v
        } catch (e: Exception) {
        }
    }

    private fun stopSound() {
        try {
            player?.stop()
        } catch (e: Exception) {
        }
        try {
            player?.release()
        } catch (e: Exception) {
        }
        player = null
        try {
            vib?.cancel()
        } catch (e: Exception) {
        }
        vib = null
    }

    @Suppress("DEPRECATION")
    override fun onDestroy() {
        h.removeCallbacks(timeout)
        stopSound()
        try {
            wl?.release()
        } catch (e: Exception) {
        }
        wl = null
        try {
            AlarmActivity.current?.finish()
        } catch (e: Exception) {
        }
        if (Build.VERSION.SDK_INT >= 24) stopForeground(Service.STOP_FOREGROUND_REMOVE) else stopForeground(true)
        super.onDestroy()
    }
}

@SuppressLint("NewApi", "SetTextI18n")
class AlarmActivity : Activity() {
    companion object {
        var current: AlarmActivity? = null
    }

    private var o: JSONObject = JSONObject()
    private val h = Handler(Looper.getMainLooper())
    private var ampm: TextView? = null
    private var clock: TextView? = null
    private var date: TextView? = null
    private val tick = object : Runnable {
        override fun run() {
            updateClock()
            h.postDelayed(this, 10000)
        }
    }

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        )
        read(intent)
        build()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        read(intent)
        build()
    }

    override fun onResume() {
        super.onResume()
        h.removeCallbacks(tick)
        h.post(tick)
    }

    override fun onPause() {
        super.onPause()
        h.removeCallbacks(tick)
    }

    override fun onDestroy() {
        h.removeCallbacks(tick)
        if (current === this) current = null
        super.onDestroy()
    }

    private fun read(i: Intent?) {
        o = try {
            JSONObject(i?.getStringExtra("json") ?: "{}")
        } catch (e: Exception) {
            JSONObject()
        }
    }

    private fun dp(v: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()

    private fun tv(text: String, sp: Float, bold: Boolean, color: Int): TextView {
        val t = TextView(this)
        t.text = text
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        t.setTextColor(color)
        t.gravity = Gravity.CENTER
        if (bold) t.typeface = Typeface.DEFAULT_BOLD
        return t
    }

    private fun btn(text: String, bg: Int, fg: Int, onTap: () -> Unit): Button {
        val b = Button(this)
        b.text = text
        b.isAllCaps = false
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
        b.setTextColor(fg)
        b.typeface = Typeface.DEFAULT_BOLD
        val d = GradientDrawable()
        d.cornerRadius = dp(40f).toFloat()
        d.setColor(bg)
        b.background = d
        b.stateListAnimator = null
        b.setOnClickListener { onTap() }
        return b
    }

    private fun updateClock() {
        val d = Date()
        ampm?.text = SimpleDateFormat("a", Locale.KOREAN).format(d)
        clock?.text = SimpleDateFormat("hh:mm", Locale.KOREAN).format(d)
        date?.text = SimpleDateFormat("yyyy.MM.dd(E)", Locale.KOREAN).format(d)
    }

    private fun build() {
        val fg = 0xFFF3EFEA.toInt()
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(0xFF262B3A.toInt())
        root.gravity = Gravity.CENTER_HORIZONTAL
        root.setPadding(dp(28f), dp(72f), dp(28f), dp(48f))

        val a = tv("", 40f, true, fg)
        val c = tv("", 84f, true, fg)
        val d = tv("", 18f, false, fg)
        ampm = a
        clock = c
        date = d
        root.addView(a)
        root.addView(c)
        root.addView(d)

        val title = tv(o.optString("title", "알람"), 26f, true, fg)
        title.setPadding(0, dp(40f), 0, dp(8f))
        root.addView(title)
        val body = o.optString("body", "")
        if (body.isNotEmpty()) root.addView(tv(body, 17f, false, 0xFFC9CCD6.toInt()))

        root.addView(View(this), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))

        val row = LinearLayout(this)
        row.orientation = LinearLayout.HORIZONTAL
        val grey = 0xFFD0D2D8.toInt()
        val dark = 0xFF2B2B2B.toInt()
        val p5 = LinearLayout.LayoutParams(0, dp(62f), 1f)
        p5.rightMargin = dp(8f)
        row.addView(btn("⏰ 5분 후", grey, dark) { snooze(5) }, p5)
        val p10 = LinearLayout.LayoutParams(0, dp(62f), 1f)
        p10.leftMargin = dp(8f)
        row.addView(btn("⏰ 10분 후", grey, dark) { snooze(10) }, p10)
        root.addView(
            row,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        )

        val sp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(72f))
        sp.topMargin = dp(18f)
        root.addView(btn("알람 종료", 0xFFFFFFFF.toInt(), dark) { stopAlarm() }, sp)

        setContentView(root)
        updateClock()
    }

    private fun snooze(min: Int) {
        AlarmKit.snooze(this, o, min)
        AlarmKit.stopRing(this)
        finish()
    }

    private fun stopAlarm() {
        AlarmKit.stopRing(this)
        finish()
    }
}
'''

src_root = APP / "android/app/src/main"
acts = list(src_root.glob("**/MainActivity.kt")) + list(src_root.glob("**/MainActivity.java"))
if acts:
    act = acts[0]
    old = act.read_text(encoding="utf-8")
    m = re.search(r"package\s+([\w.]+)", old)
    pkg = m.group(1) if m else "com.myshift.shift_calendar"
    for other in acts:
        other.unlink()
    (act.parent / "MainActivity.kt").write_text(KOTLIN.replace("PKGNAME", pkg), encoding="utf-8")
    (act.parent / "AlarmKit.kt").write_text(ALARMKIT.replace("PKGNAME", pkg), encoding="utf-8")
else:
    print("경고: MainActivity 를 찾지 못했습니다. 알람 볼륨 슬라이더가 동작하지 않을 수 있습니다.")

# 4) 패키지 설치
run(["flutter", "pub", "get"], cwd=APP)

print("\n완료! 이제 app 폴더에서 다음을 실행하세요:")
print("  PC 크롬에서 미리보기:  cd app && flutter run -d chrome")
print("  폰용 APK 만들기:       cd app && flutter build apk --release")
print("  → app/build/app/outputs/flutter-apk/app-release.apk 를 폰으로 옮겨 설치")
