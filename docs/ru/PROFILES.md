<!-- Translation of docs/en/PROFILES.md. May be outdated. -->

# Профили: Режимы выполнения для разных контекстов

## Зачем нужны профили?

Не каждому запуску CI нужен полный анализ:

| Контекст | Потребность | Приоритет |
|----------|-------------|-----------|
| Pre-commit hook | Быстрая обратная связь | Скорость |
| Before push | Уверенность | Тщательность |
| Nightly build | Полный аудит | Покрытие |
| Quick iteration | Минимальные проверки | Скорость |

Профили позволяют выбрать правильный компромисс.

## Стандартные профили

### Fast (`-Fast`)

**Use case**: Цикл самопроверки AI-агента, быстрая итерация, пре-коммит хуки.

**Этапы**: `fmt` → `lint` → `line-limits` → `build` → `(smoke)tests` → `launch`

**Пропуски**: `(huge)tests` (если 2+ минут), `coverage` (если 2+ минут), `security`, `archive`

```powershell
./run.ps1 -Fast
```

**Типичная длительность**: 5-30 секунд

### Full (по умолчанию)

**Use case**: Перед пушем, валидация PR.

**Этапы**: `fmt` → `lint` → `line-limits` → `build` → `tests` → `coverage` → `e2e` → `maintenance` → `launch`

**Пропуски**: `archive`

```powershell
./run.ps1
```

**Типичная длительность**: 1-5 минут

### Maintenance (`-Maintenance`, `-Security`, `-Clear` и т.д.)

**Use case**: Периодическое обслуживание (безопасность + зависимости + уборка + и т.д.)

Этот профиль намеренно "вне основного потока": запускайте его автоматически/вручную раз в день/неделю/перед релизом. Он может включать:
- аудит зависимостей (CVE, лицензионная политика)
- SAST / базовые сканеры безопасности
- уборка (очистка кешей/артефактов, проверки политик)

```powershell
./run.ps1 -Maintenance
```

### Release (`-Release`)

**Use case**: Сборка дистрибутивных артефактов.

**Этапы**: `fmt` → `line-limits` → `lint` → `compile` → `test` → `build` → `archive`

**Дополнительно**: Оптимизированные сборки, проставление версий

```powershell
./run.ps1 -Release
```

**Типичная длительность**: 2-10 минут

## Реализация профилей

### Выбор на основе флагов

```powershell
param(
    [switch]$Fast,
    [switch]$Release,
    [switch]$Security,
    [switch]$SkipTests,
    [switch]$SkipCoverage,
    [switch]$SkipLint
)

# Derive effective flags
$runLint = -not $SkipLint -and -not $Security
$runTests = -not $Fast -and -not $SkipTests -and -not $Security
$runCoverage = -not $Fast -and -not $SkipCoverage -and -not $Security
$runSecurity = $Security -or $Release
$runBuild = $Release
$runArchive = $Release
```

### Матрица выполнения этапов (пример Rust)

| Stage           | Fast | Full | Security | Release |
|-----------------|------|------|----------|---------|
| fmt             | ✓ | ✓ | ✗ | ✓ |
| line-limits     | ✓ | ✓ | ✗ | ✓ |
| lint            | ✓ | ✓ | ✗ | ✓ |
| build           | ✓ | ✓ | ✗ | ✓ |
| test (if fast)  | ✓ | ✓ | ✗ | ✓ |
| test            | ✗ | ✓ | ✗ | ✓ |
| coverage (fast) | ✓ | ✓ | ✗ | ✓ |
| coverage        | ✗ | ✓ | ✗ | ✓ |
| security        | ✗ | ✓ | ✓ | ✓ |
| launch          | ✓ | ✓ | ✗ | ✗ |
| archive         | ✗ | ✗ | ✗ | ✓ |

## Флаги пропуска (Skip Flags)

Тонкий контроль над отдельными этапами:

| Флаг | Эффект |
|------|--------|
| `-SkipLint` | Пропустить форматирование/линтинг (напр., `fmt`, `line-limits`, `lint`) |
| `-SkipTests` | Пропустить этап `test` |
| `-SkipCoverage` | Пропустить этап `coverage` (тесты всё равно идут) |
| `-SkipSecurity` | Пропустить этап `security` |
| `-SkipBuild` | Пропустить этап `build` |
| `-SkipLaunch` | Пропустить этап `launch` |

```powershell
# Run full profile but skip coverage (faster)
./run.ps1 -SkipCoverage

# Run everything except security
./run.ps1 -Release -SkipSecurity
```

## Справочник флагов (Пример Super-set)

Проекты обычно сходятся на небольшом наборе флагов. Полезный набор (на основе реальных раннеров) выглядит так:

| Флаг | Категория | Намерение |
|------|-----------|-----------|
| `-Fast` | profile | Быстрая обратная связь (самопроверка агента) |
| `-Release` | profile | Создание дистрибутивных артефактов |
| `-Security` | profile | Аудит только безопасности |
| `-SkipLint` | skip | Пропустить проверки формата/линта/политик |
| `-SkipTests` | skip | Пропустить этап тестов |
| `-SkipCoverage` | skip | Пропустить этап покрытия |
| `-SkipLaunch` | skip | Только CI (без интерактивного запуска) |
| `-NoCache` | cache | Игнорировать кеш (но записать новый при успехе) |
| `-ForceAll` | cache | Перезапустить все этапы |
| `-Clean` | cache | Удалить кеши/артефакты перед запуском |
| `-Verbose` | logging | Увеличить многословность инструментов |
| `-ArchiveBuild` | artifacts | Создать архив артефактов |
| `-UpdateSnapshots` | tests | Обновить снапшоты тестов во время прогона |
| `-HeartbeatSec` | heartbeat | Интервал heartbeat |
| `-HeartbeatSameLinePulses` | heartbeat | Чувствительность к зависаниям (0 выключает) |
| `-HeartbeatSameLineMinSec` | heartbeat | Включить детектор зависаний после этого времени |
| `-CoverageTimeoutSec` | heartbeat | Жесткий таймаут для этапа покрытия |

Опциональный паттерн (полезен для инструментов конкретного языка):
- Передавать аргументы после `--` из `run.ps1` в `build.<lang>` (или в CLI языка).

## Поведение запуска (Launch Behavior)

Некоторым проектам нужно запускать приложение после CI:

| Флаг | Поведение |
|------|-----------|
| (default) | Запустить CI, затем интерактивно запустить приложение |
| `-SkipLaunch` | Только CI, без запуска приложения |
| `-FastLaunch` | Пропустить CI, запустить приложение немедленно |

```powershell
# CI for AI-Agent automation
./run.ps1 -Fast -SkipLaunch

# Quick testing
./run.ps1 -Fast
```

## Пресеты профилей через конфиг

Для сложных проектов определяйте профили в конфиге:

```json
// .ci/config.json
{
  "profiles": {
    "quick": {
      "stages": ["fmt", "line-limits", "lint"],
      "timeout_sec": 60
    },
    "full": {
      "stages": ["fmt", "line-limits", "lint", "compile", "test", "coverage"],
      "timeout_sec": 600
    },
    "nightly": {
      "stages": ["fmt", "line-limits", "lint", "compile", "test", "coverage", "security"],
      "timeout_sec": 1800,
      "coverage_threshold": 80
    }
  }
}
```

Использование:
```powershell
./run.ps1 -Profile nightly
```

## Интеграция с Git Hooks

### Pre-commit (Fast)

```bash
#!/bin/sh
# .git/hooks/pre-commit
pwsh -File ./run.ps1 -Fast -SkipLaunch
```

### Pre-push (Full)

```bash
#!/bin/sh
# .git/hooks/pre-push
pwsh -File ./run.ps1 -SkipLaunch
```

## Композиция профилей

Профили можно комбинировать с флагами пропуска:

```powershell
# Release build without security scan
./run.ps1 -Release -SkipSecurity

# Fast check with lint disabled
./run.ps1 -Fast -SkipLint

# Full profile without coverage (faster tests)
./run.ps1 -SkipCoverage
```

## Рекомендуемые рабочие процессы

### Developer Workflow

```bash
# During development: fast feedback
./run.ps1 -Fast

# Before commit: full validation
./run.ps1

# Before PR: ensure CI will pass
./run.ps1 -SkipLaunch
```

### CI/CD Workflow

```bash
# PR validation
./run.ps1 -SkipLaunch

# Nightly build
./run.ps1 -Release -SkipLaunch

# Security audit (weekly)
./run.ps1 -Security -SkipLaunch
```

### Debugging Workflow

```bash
# Skip everything, just launch
./run.ps1 -FastLaunch

# Run tests only
./run.ps1 -SkipLint -SkipCoverage -SkipLaunch

# Force fresh run (ignore cache)
./run.ps1 -NoCache
```
