<!-- Translation of docs/en/REPORT_FORMAT.md. May be outdated. -->

# Формат Отчёта: Схема вывода CI

## Назначение

Структурированный JSON-отчёт позволяет:
- Программный анализ результатов CI
- Историческое отслеживание проблем во времени
- Интеграцию с внешними инструментами (дашборды, уведомления)
- Воспроизводимую отладку (точные таймстемпы, длительности)

## Обзор схемы

```json
{
  "schema_version": 1,
  "started_at_utc": "2024-01-15T10:30:00Z",
  "finished_at_utc": "2024-01-15T10:32:45Z",
  "duration_ms": 165000,
  "status": "warn",
  "stages": [...],
  "issues": [...],
  "metrics": {...}
}
```

## Полная схема

### Корневой объект

| Поле | Тип | Обязательно | Описание |
|------|-----|-------------|----------|
| `schema_version` | integer | да | Версия схемы для совместимости |
| `started_at_utc` | string (ISO 8601) | да | Время начала CI |
| `finished_at_utc` | string (ISO 8601) | да | Время окончания CI |
| `duration_ms` | integer | да | Общая длительность в мс |
| `status` | string | да | Общий статус: `ok`, `warn`, `fail` |
| `stages` | array | да | Список результатов этапов |
| `issues` | array | да | Список обнаруженных проблем |
| `metrics` | object | нет | Опциональные метрики (покрытие и т.д.) |

### Объект этапа (Stage)

```json
{
  "name": "test",
  "status": "fail",
  "note": "3 tests failed",
  "duration_ms": 12500
}
```

| Поле | Тип | Обязательно | Описание |
|------|-----|-------------|----------|
| `name` | string | да | Идентификатор этапа |
| `status` | string | да | `ok`, `warn`, `fail`, `cached`, `skip` |
| `note` | string | нет | Читаемые детали статуса |
| `duration_ms` | integer | нет | Длительность этапа |

### Объект проблемы (Issue)

```json
{
  "language": "python",
  "tool": "ruff",
  "rule": "E501",
  "count": 5,
  "message": "Line too long"
}
```

| Поле | Тип | Обязательно | Описание |
|------|-----|-------------|----------|
| `language` | string | да | Язык/контекст (напр., `python`, `rust`, `ci`) |
| `tool` | string | да | Инструмент, сообщивший о проблеме |
| `rule` | string | да | Код правила/ошибки |
| `count` | integer | да | Количество вхождений |
| `message` | string | нет | Репрезентативное сообщение |

### Объект метрик (Metrics)

```json
{
  "coverage": {
    "lines_percent": 82.5,
    "functions_percent": 78.3,
    "branches_percent": 71.2,
    "status": "warn"
  },
  "test_counts": {
    "total": 142,
    "passed": 139,
    "failed": 3,
    "skipped": 0
  }
}
```

## Пример отчёта

```json
{
  "schema_version": 1,
  "started_at_utc": "2024-01-15T10:30:00Z",
  "finished_at_utc": "2024-01-15T10:32:45Z",
  "duration_ms": 165000,
  "status": "warn",
  "stages": [
    { "name": "fmt", "status": "ok", "duration_ms": 1200 },
    { "name": "lint", "status": "warn", "note": "5 warnings", "duration_ms": 3500 },
    { "name": "compile", "status": "ok", "duration_ms": 8200 },
    { "name": "test", "status": "ok", "duration_ms": 45000 },
    { "name": "coverage", "status": "warn", "note": "72.5% < 80% threshold", "duration_ms": 95000 },
    { "name": "security", "status": "ok", "duration_ms": 12100 }
  ],
  "issues": [
    { "language": "python", "tool": "ruff", "rule": "E501", "count": 3, "message": "Line too long (> 100 chars)" },
    { "language": "python", "tool": "ruff", "rule": "F401", "count": 2, "message": "Unused import" },
    { "language": "ci", "tool": "coverage", "rule": "below_warn", "count": 1, "message": "Coverage 72.5% below 80% threshold" }
  ],
  "metrics": {
    "coverage": {
      "lines_percent": 72.5,
      "functions_percent": 68.2,
      "status": "warn"
    },
    "test_counts": {
      "total": 142,
      "passed": 142,
      "failed": 0,
      "skipped": 0
    }
  }
}
```

## Расположение файлов

| Файл | Назначение |
|------|------------|
| `.ci_cache/report.json` | Отчёт последнего прогона (перезаписывается) |
| `.ci_cache/logs/` | Полные логи инструментов (когда скрыты/обрезаны) |
| `.enforcer/Enforcer_last_check.log` | Машиночитаемый снимок последнего прогона |
| `.enforcer/Enforcer_stats.log` | Append-only исторический лог проблем |

## Консольный вывод vs Полные логи

Оркестратор должен предпочитать **компактный консольный вывод**:
- Печатать короткую сводку со статусами этапов и минимальными заметками.
- Если вывод инструмента слишком длинный или шумный, обрезайте вывод в консоли и пишите полный вывод в `.ci_cache/logs/`.
- Всегда указывайте пользователю/агенту путь к лог-файлу, когда происходит обрезка.

> Каждая строка CI должна быть максимально компактной, но содержать всю необходимую информацию. Агент должен читать CI логи только в крайних случаях.

## Исторический лог статистики

Для отслеживания трендов проблем во времени, добавляйте сводку в `Enforcer_stats.log`:

```
--- Check started at 2024-01-15T10:30:00Z ---
python: [ruff] E501 — Line too long (x3)
python: [ruff] F401 — Unused import (x2)
ci: [coverage] below_warn — Coverage 72.5% below 80% threshold (x1)
--- Check finished at 2024-01-15T10:32:45Z (status=warn) ---

--- Check started at 2024-01-15T14:20:00Z ---
python: [ruff] E501 — Line too long (x1)
--- Check finished at 2024-01-15T14:22:30Z (status=ok) ---
```

**Политика хранения**:
- Не удаляйте и не ротируйте `Enforcer_stats.log` по времени.
- Храните его, пока не проведёте обзор (еженедельно/ежемесячно) и не скорректируете правила/процесс/промпты.
- Очистка происходит только вручную, после обзора.

## Запись отчётов (Примеры)

### PowerShell

```powershell
function Write-CiReport {
    param(
        [array]$Stages,
        [array]$Issues,
        [hashtable]$Metrics,
        [string]$OutputPath
    )
    
    $overallStatus = if ($Stages | Where-Object { $_.Status -eq "fail" }) {
        "fail"
    } elseif ($Stages | Where-Object { $_.Status -eq "warn" }) {
        "warn"
    } else {
        "ok"
    }
    
    $report = @{
        schema_version = 1
        started_at_utc = $script:CiStartTime.ToString("o")
        finished_at_utc = (Get-Date).ToString("o")
        duration_ms = [int]((Get-Date) - $script:CiStartTime).TotalMilliseconds
        status = $overallStatus
        stages = $Stages
        issues = $Issues
        metrics = $Metrics
    }
    
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath
}
```

### Python

```python
import json
from datetime import datetime, timezone
from typing import List, Dict, Any

def write_ci_report(
    stages: List[Dict],
    issues: List[Dict],
    metrics: Dict,
    output_path: str,
    start_time: datetime
) -> None:
    end_time = datetime.now(timezone.utc)
    
    overall_status = "ok"
    for stage in stages:
        if stage["status"] == "fail":
            overall_status = "fail"
            break
        if stage["status"] == "warn":
            overall_status = "warn"
    
    report = {
        "schema_version": 1,
        "started_at_utc": start_time.isoformat(),
        "finished_at_utc": end_time.isoformat(),
        "duration_ms": int((end_time - start_time).total_seconds() * 1000),
        "status": overall_status,
        "stages": stages,
        "issues": issues,
        "metrics": metrics,
    }
    
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
```

## Потребление отчётов

### Проверка статуса CI

```bash
# Exit code based on report status
jq -e '.status == "ok" or .status == "warn"' .ci_cache/report.json
```

### Извлечение проваленных этапов

```bash
jq '.stages[] | select(.status == "fail") | .name' .ci_cache/report.json
```

### Подсчет проблем по инструментам

```bash
jq '[.issues[] | {tool: .tool, count: .count}] | group_by(.tool) | map({tool: .[0].tool, total: map(.count) | add})' .ci_cache/report.json
```

## Эволюция схемы

При изменении схемы:

1. Инкрементируйте `schema_version`
2. Сохраняйте обратную совместимость (новые поля должны быть опциональны)
3. Документируйте изменения в этом файле

| Версия | Изменения |
|--------|-----------|
| 1 | Начальная схема |
