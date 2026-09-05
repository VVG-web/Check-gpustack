#!/bin/bash
# Сборка приложения. Двойной клик — и рядом появится «GPUStack Монитор.app».
# Зависимостей нет: только компилятор Swift, который ставится вместе с Xcode CLT.
set -e
cd "$(dirname "$0")"

APP="GPUStack Монитор.app"
BIN="$APP/Contents/MacOS/GPUStackMonitor"

if ! command -v swiftc >/dev/null; then
  echo "Нет swiftc. Поставьте инструменты разработчика: xcode-select --install"
  exit 1
fi

echo "Собираю…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$BIN" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GPUStack Монитор</string>
  <key>CFBundleDisplayName</key><string>GPUStack Монитор</string>
  <key>CFBundleIdentifier</key><string>local.gpustack.monitor</string>
  <key>CFBundleExecutable</key><string>GPUStackMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Приложение живёт в строке меню: значок в доке ему не нужен. -->
  <key>LSUIElement</key><true/>
  <!-- Локальные серверы ходят по http: без этого macOS их запросы молча отвергнет. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <!-- Шлюз живёт во внутренней сети (10.x), а на неё macOS 15 спрашивает разрешение
       отдельно. Без этой строки система не спрашивает ВООБЩЕ и молча роняет соединение
       в таймаут: приложение показывает «шлюз не отвечает», хотя тот отвечает за 0.1 с
       из терминала — у терминала разрешение уже есть. Так и вышло при первой сборке. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Монитор опрашивает шлюз GPUStack во внутренней сети, чтобы показывать, какие модели отвечают.</string>
</dict>
</plist>
PLIST

# Первая настройка кладётся ОТСЮДА, а не приложением.
#
# Само приложение в «Документы» не ходит: собранное в .app, оно упирается в запрос
# разрешения macOS, показать который негде — значка в доке нет. Первая версия так и
# вставала на старте намертво. А этот скрипт запускают из терминала, где доступ уже есть.
#
# Адрес и ключ берутся из monitor.local.env — он в .gitignore и в репозиторий не уезжает.
# Нет файла — настройка создаётся пустой, и адрес вписывается в самом приложении:
# значок → «Настройки…». Ничьего адреса в коде нет нарочно.
SUPPORT="$HOME/Library/Application Support/GPUStackMonitor"
CFG="$SUPPORT/config.json"
if [ ! -f "$CFG" ]; then
  mkdir -p "$SUPPORT"
  URL=""
  KEY=""
  if [ -f "monitor.local.env" ]; then
    URL=$(grep -m1 '^GPUSTACK_URL=' monitor.local.env | cut -d= -f2- | tr -d '"'"'"' ')
    KEY=$(grep -m1 '^GPUSTACK_KEY=' monitor.local.env | cut -d= -f2- | tr -d '"'"'"' ')
  fi
  python3 - "$CFG" "$URL" "$KEY" <<'PYEOF'
import json, sys
path, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"url": url, "key": key, "rosterSeconds": 60, "probeSeconds": 900,
           "historyDays": 90, "hidden": {}}, open(path, "w"), ensure_ascii=False, indent=2)
PYEOF
  chmod 600 "$CFG"
  if [ -n "$URL" ]; then
    echo "Настройка создана из monitor.local.env"
  else
    echo "Настройка создана пустой — впишите адрес шлюза в приложении: значок → «Настройки…»"
    echo "или заведите monitor.local.env по образцу monitor.local.env.example и соберите заново."
  fi
fi

# Подпись «для себя»: без неё macOS ругается на неизвестного разработчика при каждом
# запуске. Ad-hoc подпись бесплатна и снимает именно это.
# Подпись с ПОСТОЯННЫМ идентификатором. Без него каждая пересборка — новое приложение
# для macOS, и разрешение на локальную сеть, выданное вчера, сегодня уже не про нас.
codesign --force --sign - --identifier local.gpustack.monitor "$APP" 2>/dev/null || true

echo "Готово: $PWD/$APP"
echo "Запустить: двойной клик по нему. Значок появится в строке меню справа."
