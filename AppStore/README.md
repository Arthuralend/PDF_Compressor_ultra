# Публикация в Mac App Store — пошагово

Всё, что можно сделать в коде, готово: песочница (App Sandbox), иконка в формате
App Store, лицензии сторонних библиотек в окне «О программе», скрипт сборки
`Scripts/build_appstore.sh` и автоматическая загрузка через GitHub Actions
(`.github/workflows/appstore.yml`). Ниже — шаги, которые делаются в вашем аккаунте Apple.

## 1. Аккаунт разработчика
* Вступите в Apple Developer Program: https://developer.apple.com/programs/ (99 $ в год).
  Для физического лица — на ваше имя; для компании нужен D-U-N-S номер.
* Team ID: developer.apple.com → Account → Membership details.

## 2. Идентификатор приложения (Bundle ID)
developer.apple.com → Certificates, IDs & Profiles → Identifiers → «+» → App IDs → App →
Platform: macOS, Bundle ID (Explicit): `com.arthuralend.pdfcompressorultra` (создан).
Дополнительные возможности (Capabilities) не нужны.

## 3. Сертификаты (нужны два)
Certificates → «+»:
1. **Apple Distribution** (или «Mac App Distribution») — подпись приложения.
2. **Mac Installer Distribution** — подпись установочного пакета.

Для каждого нужен запрос CSR: на Mac — «Связка ключей» → Ассистент сертификации →
Запросить сертификат у бюро сертификации → Сохранить на диск. Скачанные сертификаты
откройте двойным щелчком, затем в «Связке ключей» экспортируйте каждый как .p12 с паролем.

## 4. Профиль (Provisioning Profile)
Profiles → «+» → Distribution → **Mac App Store Connect** → выберите App ID из шага 2 и
сертификат Apple Distribution → скачайте файл `.provisionprofile`.

## 5. Запись приложения в App Store Connect
https://appstoreconnect.apple.com → Приложения → «+» → Новое приложение → macOS,
имя «PDF Compressor Ultra» (если занято — например «PDF Compressor Ultra — Сжатие»),
основной язык, Bundle ID из шага 2, SKU — любой (например `pdfcu`).

## 6. Ключ API для загрузки
App Store Connect → Пользователи и доступ → Интеграции → Ключи App Store Connect API →
«+» (роль App Manager) → скачайте `AuthKey_XXXXXXXXXX.p8` (скачать можно только один раз),
запишите Key ID и Issuer ID.

## 7. Секреты в GitHub
Репозиторий → Settings → Secrets and variables → Actions → New repository secret.
Файлы кладутся в base64 (на Mac: `base64 -i файл | pbcopy`, затем вставить).

| Секрет | Что положить |
|---|---|
| `APPSTORE_TEAM_ID` | Team ID |
| `APPSTORE_APP_CERT_P12` | base64 .p12 сертификата Apple Distribution |
| `APPSTORE_INSTALLER_CERT_P12` | base64 .p12 сертификата Mac Installer Distribution |
| `APPSTORE_CERT_PASSWORD` | пароль .p12 (одинаковый для обоих) |
| `APPSTORE_PROFILE` | base64 файла .provisionprofile |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | base64 файла AuthKey_….p8 |

## 8. Сборка и загрузка
GitHub → Actions → **App Store upload** → Run workflow → укажите версию (например 1.0.0).
Через 5–20 минут после загрузки сборка появится в App Store Connect → TestFlight
(можно проверить приложение на своём Mac через TestFlight).

Альтернатива без GitHub: на своём Mac задайте переменные из шапки
`Scripts/build_appstore.sh` и запустите его, затем загрузите `.pkg` приложением
Transporter из Mac App Store.

## 9. Страница в магазине
App Store Connect → приложение → версия 1.0:
* тексты — `AppStore/listing_ru.md` и `AppStore/listing_en.md`;
* **скриншоты** — минимум 1, размер 1280×800, 1440×900, 2560×1600 или 2880×1800;
* **Privacy Policy URL** — обязателен. Опубликуйте `AppStore/privacy.html` на любом сайте
  (например GitHub Pages) и вставьте ссылку;
* Support URL — сайт или страница с контактами;
* App Privacy → «Data Not Collected»;
* Цена и доступность; возрастной рейтинг (анкета → 4+);
* Экспортные ограничения: приложение использует только системное шифрование
  (`ITSAppUsesNonExemptEncryption = NO` уже стоит в сборке);
* выберите загруженную сборку → **Отправить на проверку** (обычно 1–3 дня).

## Что изменилось для пользователя в версии App Store
В App Store приложение работает в «песочнице»: оно может писать только в папки,
которые пользователь разрешил. При сохранении «рядом с оригиналом» программа один раз
попросит разрешить доступ к папке и запомнит это. Утилита командной строки `pdfcu`
в версию для App Store не входит.
