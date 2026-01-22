<!-- Translation of docs/en/HEARTBEAT.md. May be outdated. -->

# Heartbeat: Паттерны Watchdog для обнаружения зависаний

## Проблема

Долгоживущие этапы могут:
- Молча зависать (deadlocks, бесконечные циклы)
- Выглядеть застрявшими, когда на самом деле медленно прогрессируют
- Вылетать по таймауту без полезной диагностики

Без мониторинга "пульса" (heartbeat) вы смотрите на замерший терминал, гадая, работает оно или нет.

## Решение: Heartbeat Monitoring

Периодически выводите информацию о прогрессе во время длительных команд:

```
[heartbeat] coverage alive t+00:01:00 last-out=5s line='running test_integration'
[heartbeat] coverage alive t+00:02:00 last-out=3s line='test result: ok. 50 passed'
[heartbeat] coverage alive t+00:03:00 last-out=45s line='test result: ok. 50 passed'
[heartbeat] coverage appears stuck: no output for 60s, terminating...
```

Heartbeat — это не только монитор: это сторожевой пес (watchdog), который может завершить зависшие или превысившие таймаут процессы, но всё равно выдать отчёт и ссылки на логи.

### Реальный пример ([в стиле LivingLayers](https://livinglayers.ru/?utm_source=github&utm_medium=organic&utm_campaign=agentenforcer2&utm_content=heartbeat.md))

Некоторые проекты обогащают строки heartbeat дополнительным контекстом, особенно когда вывод захватывается в лог:

```
[heartbeat] coverage output captured to: cargo_coverage_20260122_115735_40278d.log (temp; kept on failure)
cargo run --manifest-path tools/ll-ci/Cargo.toml -- coverage
[heartbeat] coverage alive t+00:01:00 last-out=60s line='[stderr] Running `target\debug\ll-ci.exe coverage`' pid=40268 hidden log=cargo_coverage_20260122_115735_40278d.log procs=cargo.exe x3, ll-ci.exe x1 target=1 phase=run arm-in=300s
[heartbeat] coverage alive t+00:05:00 last-out=300s line='[stderr] Running `target\debug\ll-ci.exe coverage`' pid=40268 hidden log=cargo_coverage_20260122_115735_40278d.log phase=compile procs=rustc.exe x4, sccache.exe x4, cargo.exe x3 target=1 arm-in=60s
[heartbeat] coverage alive t+00:07:00 last-out=15s line='[stderr] warning: --no-run is deprecated ...' pid=40268 hidden log=cargo_coverage_20260122_115735_40278d.log phase=coverage procs=cargo-llvm-cov.exe x1, cargo.exe x3 same=1/3
```

Примечания:
- `pid`, `procs` и `phase` помогают отличить реальное зависание от медленной компиляции/линковки.
- `arm-in` делает обнаружение зависаний предсказуемым (детектирование начинается только после периода "разогрева").
- `same=1/3` счетчик одинаковых снимков перед прерыванием.

## Параметры Heartbeat

| Параметр | По умолчанию | Описание |
|----------|--------------|----------|
| `HeartbeatSec` | 60 | Интервал между сообщениями heartbeat |
| `TimeoutSec` | 0 | Макс. время работы до принудительного убийства (0 = выкл) |
| `SameLineHangPulses` | 3 | Последовательные heartbeats с одинаковым выводом = зависание |
| `SameLineHangMinSec` | 360 | Мин. время работы перед включением детектора зависаний |

## Стратегии обнаружения зависаний

### 1. Таймаут отсутствия вывода

Убить процесс, если нет stdout/stderr в течение X секунд.

```
if (seconds_since_last_output > 120):
    mark_as_hung()
    kill_process()
```

**Проблема**: Некоторые этапы легитимно не производят вывод долгое время.

### 2. Same-Line Detection (Детекция повтора строки)

Убить процесс, если последняя строка вывода повторяется N последовательных heartbeats.

```
if (last_output_line == previous_last_output_line):
    same_line_streak++
    if (same_line_streak >= SameLineHangPulses AND runtime > SameLineHangMinSec):
        mark_as_hung()
        kill_process()
else:
    same_line_streak = 0
```

**Лучше**: Ловит сценарии "застрял на 99%" без ложных срабатываний на медленных тестах.

### 3. Сигнатура прогресса

Извлечь "сигнатуру прогресса" из вывода (напр., счетчик тестов) и детектировать, если он перестал расти.

```
# Parse test runner output
signature = extract_progress(output)  # e.g., "142/500 tests"

if (signature == previous_signature):
    stall_count++
else:
    stall_count = 0
    previous_signature = signature
```

## Реализация (Псевдокод)

```powershell
function Invoke-CommandWithHeartbeat {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$Label,
        [int]$HeartbeatSec = 60,
        [int]$TimeoutSec = 0,
        [int]$SameLineHangPulses = 3,
        [int]$SameLineHangMinSec = 360
    )
    
    $startTime = Get-Date
    $lastOutputTime = Get-Date
    $lastOutputLine = ""
    $sameLineStreak = 0
    $outputBuffer = [System.Collections.ArrayList]::new()
    
    # Start process with redirected output
    $process = Start-Process -FilePath $Command -ArgumentList $Arguments `
        -NoNewWindow -PassThru -RedirectStandardOutput "stdout.tmp" -RedirectStandardError "stderr.tmp"
    
    # Monitor loop
    while (-not $process.HasExited) {
        Start-Sleep -Seconds $HeartbeatSec
        
        $elapsed = (Get-Date) - $startTime
        $sinceLast = (Get-Date) - $lastOutputTime
        
        # Read new output
        $newOutput = Get-TailOutput -Path "stdout.tmp"
        if ($newOutput) {
            $lastOutputTime = Get-Date
            $currentLine = $newOutput | Select-Object -Last 1
        }
        
        # Heartbeat message
        $snippet = if ($currentLine.Length -gt 60) { 
            $currentLine.Substring(0, 57) + "..." 
        } else { 
            $currentLine 
        }
        Write-Host "[heartbeat] $Label alive t+$($elapsed.ToString('hh\:mm\:ss')) last-out=$([int]$sinceLast.TotalSeconds)s line='$snippet'"
        
        # Same-line hang detection
        if ($currentLine -eq $lastOutputLine) {
            $sameLineStreak++
            if ($sameLineStreak -ge $SameLineHangPulses -and 
                $elapsed.TotalSeconds -gt $SameLineHangMinSec) {
                Write-Warning "[heartbeat] $Label appears stuck: same output for $sameLineStreak heartbeats"
                $process.Kill()
                return @{ ExitCode = -1; Hung = $true }
            }
        } else {
            $sameLineStreak = 0
            $lastOutputLine = $currentLine
        }
        
        # Timeout check
        if ($TimeoutSec -gt 0 -and $elapsed.TotalSeconds -gt $TimeoutSec) {
            Write-Warning "[heartbeat] $Label timed out after $TimeoutSec seconds"
            $process.Kill()
            return @{ ExitCode = -1; TimedOut = $true }
        }
    }
    
    return @{ ExitCode = $process.ExitCode; Hung = $false; TimedOut = $false }
}
```

## Логирование вывода

Захватывайте полный вывод в лог-файлы для посмертного анализа:

```powershell
$logDir = ".ci_cache/logs"
$logPath = Join-Path $logDir "$Label_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

# Write header
@"
---
command: $Command $($Arguments -join ' ')
started: $(Get-Date -Format 'o')
---
"@ | Set-Content $logPath

# Append output during execution
$output | Add-Content $logPath

# Write footer on completion
@"
---
exit_code: $exitCode
elapsed_ms: $elapsedMs
---
"@ | Add-Content $logPath
```

## Интеграция с Оркестратором

```powershell
# build.ps1

$coverageResult = Invoke-CommandWithHeartbeat `
    -Command "cargo" `
    -Arguments @("llvm-cov", "--workspace", "--all-features") `
    -Label "coverage" `
    -HeartbeatSec $HeartbeatSec `
    -TimeoutSec $CoverageTimeoutSec `
    -SameLineHangPulses $HeartbeatSameLinePulses `
    -SameLineHangMinSec $HeartbeatSameLineMinSec

if ($coverageResult.Hung) {
    $StageResults += @{ Name = "coverage"; Status = "fail"; Note = "Process hung" }
} elseif ($coverageResult.TimedOut) {
    $StageResults += @{ Name = "coverage"; Status = "fail"; Note = "Timed out" }
} elseif ($coverageResult.ExitCode -ne 0) {
    $StageResults += @{ Name = "coverage"; Status = "fail"; Note = "Exit code: $($coverageResult.ExitCode)" }
} else {
    $StageResults += @{ Name = "coverage"; Status = "ok" }
}
```

## CLI флаги для управления Heartbeat

```powershell
param(
    [int]$HeartbeatSec = 60,
    [int]$HeartbeatSameLinePulses = 3,
    [int]$HeartbeatSameLineMinSec = 360,
    [int]$CoverageTimeoutSec = 0
)
```

Использование:
```bash
# Faster heartbeat for debugging
./run.ps1 -HeartbeatSec 10

# Disable hang detection (useful for known-slow tests)
./run.ps1 -HeartbeatSameLinePulses 0

# Set hard timeout for coverage
./run.ps1 -CoverageTimeoutSec 600
```

## Лучшие практики

1. **Не подавляйте вывод**: Heartbeat нуждается в выводе, чтобы детектировать прогресс.
2. **Логируйте всё**: Полные логи критичны для отладки зависаний.
3. **Настраивайте пороги под проект**: 3-минутная "тишина" нормальна для некоторых тестов.
4. **Падайте грациозно**: Зависшие процессы всё равно должны генерировать отчёт.
5. **Очищайте**: Убивайте дочерние процессы, удаляйте временные файлы при зависании/таймауте.
