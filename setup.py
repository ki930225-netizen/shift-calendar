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

for perm in ("READ_CALENDAR", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"):
    if perm not in text:
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
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("native", e.message, null)
                }
            }
    }
}
"""

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
else:
    print("경고: MainActivity 를 찾지 못했습니다. 알람 볼륨 슬라이더가 동작하지 않을 수 있습니다.")

# 4) 패키지 설치
run(["flutter", "pub", "get"], cwd=APP)

print("\n완료! 이제 app 폴더에서 다음을 실행하세요:")
print("  PC 크롬에서 미리보기:  cd app && flutter run -d chrome")
print("  폰용 APK 만들기:       cd app && flutter build apk --release")
print("  → app/build/app/outputs/flutter-apk/app-release.apk 를 폰으로 옮겨 설치")
