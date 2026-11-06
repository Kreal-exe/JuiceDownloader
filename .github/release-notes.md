**Windows.** Download `JuiceDownloader-Windows-v<version>.exe` and run it — one file, nothing to install, no .NET needed.
Windows 10 1903 or later. The app is not signed yet: if SmartScreen stops it, choose **More info → Run anyway**.

**macOS.** Open `JuiceDownloader-macOS-v<version>.dmg` and drag `JuiceDownloader.app` onto *Applications*. The build is not
notarized yet, so before the first launch run **Allow JuiceDownloader to open.command** from the disk image (right-click →
*Open* the first time): it copies the app to Applications if needed, clears the quarantine flag and opens it. Or by hand:

```bash
xattr -dr com.apple.quarantine /Applications/JuiceDownloader.app
```

Or: *System Settings → Privacy & Security* → **Open Anyway**. macOS 12 or later, Apple Silicon or Intel.

**Linux.** `JuiceDownloader-Linux-v<version>.AppImage`: make it executable (`chmod +x`) and run it. Self-contained, no .NET
needed; x86-64, any desktop (GNOME, KDE, Xfce…).

---

**Windows.** Скачайте `JuiceDownloader-Windows-v<version>.exe` и запустите — один файл, устанавливать ничего не нужно, .NET
не нужен. Windows 10 1903 или новее. Приложение пока не подписано: если SmartScreen его остановит, нажмите
**«Подробнее» → «Выполнить в любом случае»**.

**macOS.** Откройте `JuiceDownloader-macOS-v<version>.dmg` и перетащите `JuiceDownloader.app` в «Программы». Сборка пока не
нотаризована, поэтому перед первым запуском запустите из образа **Allow JuiceDownloader to open.command** (в первый раз —
правый клик → «Открыть»): он скопирует приложение в «Программы», если его там нет, снимет карантин и откроет его.
Или вручную:

```bash
xattr -dr com.apple.quarantine /Applications/JuiceDownloader.app
```

Или: «Системные настройки» → «Конфиденциальность и безопасность» → **«Всё равно открыть»**. macOS 12 или новее,
Apple Silicon или Intel.

**Linux.** `JuiceDownloader-Linux-v<version>.AppImage`: сделайте файл исполняемым (`chmod +x`) и запустите. Всё своё внутри,
.NET не нужен; x86-64, любое окружение (GNOME, KDE, Xfce…).
