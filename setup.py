#!/usr/bin/env python3
"""근무 캘린더 앱 설치 스크립트.

이 폴더(shift_calendar)에서 `python3 setup.py` 를 실행하면
  1) 안드로이드용 Flutter 프로젝트(app/)를 만들고
  2) lib/main.dart, pubspec.yaml 을 복사하고
  3) 알람에 필요한 권한/설정을 자동으로 패치하고
  4) flutter pub get 까지 실행합니다.
"""
import re
import shutil
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

if "ScheduledNotificationReceiver" not in text:
    receivers = """        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
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

# 4) 패키지 설치
run(["flutter", "pub", "get"], cwd=APP)

print("\n완료! 이제 app 폴더에서 다음을 실행하세요:")
print("  PC 크롬에서 미리보기:  cd app && flutter run -d chrome")
print("  폰용 APK 만들기:       cd app && flutter build apk --release")
print("  → app/build/app/outputs/flutter-apk/app-release.apk 를 폰으로 옮겨 설치")
