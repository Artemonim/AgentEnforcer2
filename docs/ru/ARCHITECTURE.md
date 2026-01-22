<!-- Translation of docs/en/ARCHITECTURE.md. May be outdated. -->

# Архитектура: Трехуровневый Локальный CI

## Обзор

```
┌─────────────────────────────────────────────────────────────┐
│                      User / AI-Agent                        │
│                           │                                 │
│                           ▼                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    run.ps1                           │   │
│  │              (Thin Wrapper Layer)                    │   │
│  │  • Валидирует CLI флаги                              │   │
│  │  • Показывает help                                   │   │
│  │  • Передает управление в build.ps1                   │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   build.ps1                          │   │
│  │             (Orchestrator Layer)                     │   │
│  │  • Управляет порядком выполнения этапов              │   │
│  │  • Обрабатывает кеширование (хеши, trust stamps)     │   │
│  │  • Запускает мониторинг heartbeat                    │   │
│  │  • Собирает результаты этапов                        │   │
│  │  • Генерирует финальный отчёт                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                 │
│          ┌────────────────┼─────────────────┐               │
│          ▼                ▼                 ▼               │
│   ┌─────────────┐  ┌─────────────┐  ┌────────────────┐      │
│   │  build.py   │  │  build.rs   │  │  build.<lang>  │      │
│   │  (Python)   │  │   (Rust)    │  │    (<lang>)    │      │
│   │             │  │             │  │                │      │
│   │  Специфичная│  │  Специфичная│  │  Специфичная   │      │
│   │  для языка  │  │  для языка  │  │  для языка     │      │
│   │  логика     │  │  логика     │  │  логика        │      │
│   └─────────────┘  └─────────────┘  └────────────────┘      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Уровень 1: Тонкая обертка (`run.ps1`)

**Назначение**: Точка входа для агента с минимальной логикой.

**Обязанности**:
- Парсинг и валидация CLI флагов
- Раннее обнаружение неизвестных/невалидных параметров
- Отображение справки
- Передача выполнения в `build.ps1`

**Зачем отделять от оркестратора?**
- Сохраняет точку входа простой и читаемой: AI-агент скорее всего прочитает entrypoint CI, даже если это не требуется для задачи. Когда это "*всего лишь*" полный интерфейс CI, вы можете безопасно включить `run.ps1` в контекст промпта целиком.
- Позволяет иметь разные точки входа (например, `run.ps1`, `ci.ps1`, `check.ps1`)

### Псевдокод

```powershell
# run.ps1 — Thin wrapper

param(
    [switch]$Fast,
    [switch]$SkipTests,
    [switch]$Help
)

# Known parameters for validation
$knownParams = @('Fast', 'SkipTests', 'Help')

# Reject unknown parameters
if ($args) {
    Write-Error "Unknown parameter(s): $($args -join ', ')"
    exit 1
}

# Show help
if ($Help) {
    Show-Help
    exit 0
}

# Forward to orchestrator
& "$PSScriptRoot/build.ps1" @PSBoundParameters
exit $LASTEXITCODE
```

## Уровень 2: Оркестратор (`build.ps1`)

**Назначение**: Центральное управление пайплайном CI.

**Обязанности**:
- Определение порядка и зависимостей этапов
- Управление профилями выполнения
- Полное владение средой выполнения на машине разработчика для целевого проекта (что запускается вокруг кода)
- Подготовка и проверка пререквизитов (SDK, тулчейны, PATH, переменные среды, virtualenvs, локальная инфраструктура)
- Управление проблемами "внешнего мира" build/runtime (временные папки, кеши, артефакты, лог-файлы)
- Обработка кеширования (проверка хешей, запись меток доверия)
- Запуск команд с мониторингом heartbeat
- Сбор результатов этапов в структурированный отчёт
- Очистка и управление артефактами

**Ключевые структуры данных**:

```powershell
# Stage result object
$StageResult = @{
    Name   = "test"
    Status = "ok"      # ok | warn | fail | cached | skip
    Note   = ""        # Optional details
}

# CI Report (written to .ci_cache/report.json)
$CiReport = @{
    schema_version  = 1
    started_at_utc  = "2024-01-15T10:30:00Z"
    finished_at_utc = "2024-01-15T10:32:45Z"
    duration_ms     = 165000
    status          = "ok"    # ok | warn | fail
    stages          = @()     # Array of StageResult
    issues          = @()     # Array of detected issues
}
```

### Псевдокод

```powershell
# build.ps1 — Orchestrator

param([switch]$Fast, [switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$StageResults = @()
$CacheDir = ".ci_cache"

# Stage execution helper
function Invoke-Stage {
    param([string]$Name, [scriptblock]$Action, [switch]$Critical)
    
    try {
        $result = & $Action
        $StageResults += @{ Name = $Name; Status = "ok" }
    }
    catch {
        $StageResults += @{ Name = $Name; Status = "fail"; Note = $_.Message }
        if ($Critical) { throw }
    }
}

# Run stages
Invoke-Stage -Name "fmt" -Critical -Action {
    # Call language-specific formatter
}

Invoke-Stage -Name "lint" -Critical -Action {
    # Call language-specific linter
}

if (-not $SkipTests) {
    Invoke-Stage -Name "test" -Critical -Action {
        # Call language-specific test runner
    }
}

if (-not $Fast) {
    Invoke-Stage -Name "coverage" -Action {
        # Call language-specific coverage tool
    }
}

# Write final report
Write-CiReport -Stages $StageResults -OutputPath "$CacheDir/report.json"
```

## Уровень 3: Специфичная для языка логика (`build.<lang>`)

**Назначение**: Инкапсуляция всех инструментов языка/фреймворка.

**Обязанности**:
- Конфигурация и запуск линтеров (ruff, eslint, clippy и т.д.)
- Запуск тестовых фреймворков (pytest, vitest, cargo test и т.д.)
- Сбор данных покрытия
- Парсинг вывода инструментов в структурированный формат
- Обработка языковых пограничных случаев (edge cases)

**Зачем отделять?**
- Оркестратор остаётся независимым от языка
- Легко добавить новые языки без изменения оркестратора
- Эксперты по языку могут поддерживать свою секцию независимо
- Может быть заменено на скомпилированные инструменты для производительности (например, Rust CLI)

### Псевдокод (Python)

```python
# build.py — Python-specific CI logic

import subprocess
import json
import sys

TOOLS = {
    "ruff-format": {
        "command": ["ruff", "format", "--check"],
        "fix_command": ["ruff", "format"],
        "critical": False,
    },
    "ruff-lint": {
        "command": ["ruff", "check"],
        "critical": True,
    },
    "pytest": {
        "command": ["pytest", "-q", "--tb=short"],
        "critical": True,
    },
}

def run_tool(name: str, fix: bool = False) -> dict:
    config = TOOLS[name]
    cmd = config.get("fix_command") if fix else config["command"]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    return {
        "tool": name,
        "exit_code": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "critical": config["critical"],
    }

def main():
    results = []
    for tool_name in ["ruff-format", "ruff-lint", "pytest"]:
        results.append(run_tool(tool_name))
    
    # Output JSON for orchestrator to consume
    json.dump(results, sys.stdout)

if __name__ == "__main__":
    main()
```

## Поток данных

```
1. User runs: ./run.ps1 -Fast

2. run.ps1:
   - Validates -Fast is known
   - Forwards to build.ps1 -Fast

3. build.ps1:
   - Checks hash cache for "lint" stage
   - Cache hit → skips lint (status: cached)
   - -Fast flag → skips heavy tools
   - Collects all stage results
   - Writes .ci_cache/report.json

4. build.py (called by build.ps1 for Python stages):
   - Runs ruff format --check
   - Runs ruff check
   - Returns JSON with tool results

5. Output:
   - Console: Stage-by-stage status
   - File: .ci_cache/report.json
   - Exit code: 0 (success) or 1 (failure)
```

## Консольная сводка (High-Signal Output)

Оркестратор должен печатать компактную сводку в конце прогона:
- Стабильный список этапов с `OK | WARN | FAIL | CACHED | SKIP`
- Короткие заметки (% покрытия, топ нарушителей, однострочные ошибки)
- Указатели на лог-файлы, когда вывод слишком длинный или шумный

**Цель**: агент может итерироваться в автоматическом цикле:
`write code → run local CI → fix → repeat`, без того чтобы человек копипастил логи ошибок в чат.

## Структура директорий

```
project/
├── run.ps1              # Thin wrapper (entry point)
├── build.ps1            # Orchestrator
├── build.py             # Python-specific logic (optional)
├── build.ts             # TypeScript-specific logic (optional)
├── tools/
│   └── ci/              # Compiled CI helpers (optional)
│       └── src/
│           └── main.rs
├── .ci_cache/           # Cache directory (gitignored)
│   ├── report.json      # Last CI run report
│   ├── fmt.sha256       # Hash for fmt stage
│   ├── fmt.trusted      # Trust stamp for fmt stage
│   └── logs/            # Command output logs
├── .enforcer/            # Persistent local CI logs
│   ├── Enforcer_last_check.log
│   └── Enforcer_stats.log
└── .ci/                 # CI configuration (optional)
    └── config.json      # Custom thresholds, disabled rules, etc.
```

## Когда использовать какой уровень

| Задача | Уровень | Пример |
|--------|---------|--------|
| Добавить новый CLI флаг | `run.ps1` | `[switch]$Verbose` |
| Добавить новый этап | `build.ps1` | Security scanning stage |
| Изменить логику кеширования | `build.ps1` | Другой алгоритм хеширования |
| Добавить новый линтер | `build.<lang>` | Добавить mypy в Python |
| Парсить вывод инструмента | `build.<lang>` | Извлечь % покрытия |
| Сложный анализ | `tools/ci/` | Алгоритм ранжирования покрытия |
