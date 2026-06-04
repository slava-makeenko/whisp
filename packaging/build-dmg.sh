#!/usr/bin/env bash
#
# Сборка стилизованного, самодостаточного, подписанного DMG для установки whisp.
#
#   packaging/build-dmg.sh                 # → ~/Desktop/whisp.dmg
#   packaging/build-dmg.sh /путь/out.dmg   # свой путь вывода
#   WHISP_SIGN_IDENTITY="Apple Development: …" packaging/build-dmg.sh   # другой сертификат
#
# ⚠️  Первый запуск спросит разрешение «… wants to control Finder» — нажми OK
#     (нужно, чтобы Finder применил фон и расставил иконки в окне DMG).
#
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="${1:-$HOME/Desktop/whisp.dmg}"
IDENTITY="${WHISP_SIGN_IDENTITY:-Apple Development: makslav96@gmail.com (44K83FNU65)}"
VOL="whisp"
RW="${TMPDIR:-/tmp}/whisp-rw.dmg"

cleanup() { hdiutil detach -force "/Volumes/$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "▶︎ 1/6  Release-сборка (LOCAL_BUILD — без CloudKit/Sparkle-заглушек)"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project whisp.xcodeproj -scheme whisp -configuration Release \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="LOCAL_BUILD" build >/dev/null
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name whisp.app \
  -path '*/Build/Products/Release/*' | grep -v Index.noindex | head -1)
[ -n "$APP" ] || { echo "✗ Release whisp.app не найден"; exit 1; }
echo "   $APP"

echo "▶︎ 2/6  Подпись"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify "$APP"

echo "▶︎ 3/6  Проверка самодостаточности (единственный внешний dylib — Sparkle)"
EXT=$(otool -L "$APP/Contents/MacOS/whisp" | grep -E '@rpath|@executable' | grep -v Sparkle || true)
[ -z "$EXT" ] || { echo "✗ неожиданные внешние зависимости:"; echo "$EXT"; exit 1; }

echo "▶︎ 4/6  Рендер фона окна"
BGDIR="$(mktemp -d)"
swift "$HERE/dmg-background.swift" "$BGDIR/background.png" >/dev/null

echo "▶︎ 5/6  RW-образ + раскладка окна Finder"
cleanup; rm -f "$RW"
hdiutil create -size 90m -fs HFS+ -volname "$VOL" -o "$RW" >/dev/null
MNT=$(hdiutil attach "$RW" -nobrowse -noautoopen | grep -o '/Volumes/.*' | head -1)
[ "$MNT" = "/Volumes/$VOL" ] || { echo "✗ том примонтирован как '$MNT', ожидался /Volumes/$VOL"; exit 1; }
ditto "$APP" "$MNT/whisp.app"
ln -s /Applications "$MNT/Applications"
mkdir -p "$MNT/.background"
cp "$BGDIR/background.png" "$MNT/.background/background.png"
osascript "$HERE/dmg-layout.applescript"
sync; sync
[ -f "$MNT/.DS_Store" ] || echo "⚠️  .DS_Store не записан — раскладка может не примениться"
hdiutil detach "$MNT" >/dev/null

echo "▶︎ 6/6  Сжатие в UDZO → $OUT"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
hdiutil verify "$OUT" >/dev/null

echo "✓ Готово: $OUT  ($(du -h "$OUT" | cut -f1))"
echo "  Установка: открыть DMG → перетащить whisp в Applications."
echo "  На чужом Mac (скачанный DMG) Gatekeeper заблокирует не-нотаризованную подпись —"
echo "  обход: ПКМ по приложению → «Открыть»."
