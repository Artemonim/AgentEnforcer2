<!-- Translation of docs/en/CACHING.md. May be outdated. -->

# Кеширование: Hash Guards и Метки Доверия

## Зачем кешировать?

Без кеширования CI запускает каждый этап при каждом вызове, даже если ничего не изменилось. Это тратит время и ломает цикл быстрой обратной связи.

Хорошее кеширование должно:
- Пропускать этапы, когда исходные файлы не изменились
- Инвалидироваться, когда меняются релевантные файлы
- Быть детерминированным (одинаковые входы → одинаковое решение кеша)
- Быть прозрачным (легко форсировать перезапуск)

## Компоненты кеша

### 1. Hash Files (`.sha256`)

Хранят хеш всех входных данных, релевантных для этапа.

```
.ci_cache/
├── fmt.sha256       # Hash of source files for fmt stage
├── lint.sha256      # Hash of source files + lint config
├── test.sha256      # Hash of source + test files
└── coverage.sha256  # Hash of source + test files + coverage config
```

**Вычисление хеша**:
```
hash = SHA256(
    sorted(file_paths) +
    sorted(file_contents)
)
```

**Что включать в хеш**:
- Исходные файлы (`.py`, `.rs`, `.ts`, etc.)
- Конфигурационные файлы (`.eslintrc`, `pyproject.toml`, etc.)
- Lock-файлы (`Cargo.lock`, `package-lock.json`, etc.)

**Что исключать**:
- Директорию `.git/`
- Артефакты сборки (`target/`, `dist/`, `node_modules/`)
- Директории кеша (`.ci_cache/`)
- Настройки IDE (`.vscode/`, `.idea/`)

### 2. Trust Stamps (`.trusted`)

Указывают, что этап был ранее успешно пройден для данного хеша.

```
.ci_cache/
├── fmt.sha256       # Contains: a1b2c3d4...
├── fmt.trusted      # Exists only if fmt passed for a1b2c3d4...
```

**Логика**:
```
if hash_file_exists AND hash_matches_current AND trust_file_exists:
    → Cache hit, skip stage
else:
    → Cache miss, run stage
    if stage_passed:
        → Write new hash + trust stamp
```

## Поток кеширования

1. Вычислить текущий хеш:
```py
current_hash = hash(src/**/*.py, .ruff.toml)
```
2. Прочитать сохранённый хеш:
```py
stored_hash = read(".ci_cache/lint.sha256")
```
3. Проверить валидность кеша
```py
if stored_hash == current_hash
   AND exists(".ci_cache/lint.trusted"):
   → CACHED (cache hit)
else:
   → RUN stage
```
4. После успешного прогона
```py
write(".ci_cache/lint.sha256", current_hash)
touch(".ci_cache/lint.trusted")
```

## Псевдокод

```powershell
function Test-StageCache {
    param(
        [string]$StageName,
        [string[]]$InputPaths,
        [string]$CacheDir = ".ci_cache"
    )
    
    $hashFile = Join-Path $CacheDir "$StageName.sha256"
    $trustFile = Join-Path $CacheDir "$StageName.trusted"
    
    # Compute current hash
    $currentHash = Get-ContentHash -Paths $InputPaths
    
    # Check stored hash
    $storedHash = if (Test-Path $hashFile) { 
        Get-Content $hashFile 
    } else { 
        "" 
    }
    
    # Cache hit?
    if ($currentHash -eq $storedHash -and (Test-Path $trustFile)) {
        return @{ CacheHit = $true; Hash = $currentHash }
    }
    
    return @{ CacheHit = $false; Hash = $currentHash }
}

function Write-StageCache {
    param(
        [string]$StageName,
        [string]$Hash,
        [string]$CacheDir = ".ci_cache"
    )
    
    $hashFile = Join-Path $CacheDir "$StageName.sha256"
    $trustFile = Join-Path $CacheDir "$StageName.trusted"
    
    Set-Content -Path $hashFile -Value $Hash
    New-Item -ItemType File -Path $trustFile -Force | Out-Null
}

function Clear-StageCache {
    param(
        [string]$StageName,
        [string]$CacheDir = ".ci_cache"
    )
    
    Remove-Item -Path (Join-Path $CacheDir "$StageName.*") -Force -ErrorAction SilentlyContinue
}
```

## Инвалидация кеша

### Автоматическая инвалидация

Кеш автоматически инвалидируется, когда:
- Меняются исходные файлы (хеш не совпадает)
- Меняются конфиги (если включены в хеш)
- Меняются lock-файлы (обновлены зависимости)

### Ручная инвалидация

Предоставьте CLI флаги для ручного управления кешем:

| Флаг | Эффект |
|------|--------|
| `-NoCache` | Игнорировать кеш, но всё равно записать новый при успехе |
| `-ForceAll` | Подразумевает `-NoCache`, перезапуск всего |
| `-Clean` | Удалить директорию кеша перед запуском |

```powershell
# run.ps1 flags
param(
    [switch]$NoCache,     # Ignore cache for this run
    [switch]$ForceAll,    # Force all stages to re-run
    [switch]$Clean        # Delete cache before running
)
```

## Входы хеша по этапам (Per-Stage Hash Inputs)

У разных этапов разные входы:

| Этап | Входы хеша |
|------|------------|
| `fmt` | Только исходные файлы |
| `lint` | Исходные файлы + конфиг линтера (`.ruff.toml`, `.eslintrc`) |
| `compile` | Исходные файлы + конфиг сборки + lock-файлы |
| `test` | Исходники + тесты + конфиг тестов |
| `coverage` | То же, что тест + конфиг покрытия |

```powershell
$StageInputs = @{
    "fmt" = @("src/**/*.py")
    "lint" = @("src/**/*.py", ".ruff.toml", "pyproject.toml")
    "test" = @("src/**/*.py", "tests/**/*.py", "pyproject.toml")
    "coverage" = @("src/**/*.py", "tests/**/*.py", "pyproject.toml", ".coveragerc")
}
```

## Ежедневное/Периодическое устаревание кеша

Некоторые проверки должны запускаться хотя бы раз в день, даже без изменений кода:

```powershell
function Test-RunEnvChecksToday {
    param([switch]$Force)
    
    $stampFile = ".ci_cache/env_check.stamp"
    $today = (Get-Date).ToString("yyyy-MM-dd")
    
    if ($Force) { return $true }
    
    if (Test-Path $stampFile) {
        $stampDate = Get-Content $stampFile
        if ($stampDate -eq $today) {
            return $false  # Already ran today
        }
    }
    
    return $true  # Need to run
}
```

## Структура директории кеша

```
.ci_cache/
├── fmt.sha256          # Hash for fmt stage
├── fmt.trusted         # Trust stamp for fmt stage
├── lint.sha256
├── lint.trusted
├── test.sha256
├── test.trusted
├── coverage.sha256
├── coverage.trusted
├── env_check.stamp     # Date of last environment check
├── report.json         # Last CI run report
├── logs/               # Command output logs
│   ├── lint_2024-01-15.log
│   └── test_2024-01-15.log
└── temp/               # Temporary files (cleaned on exit)
```

## Gitignore

Добавьте в `.gitignore`:

```gitignore
# Local CI cache
.ci_cache/
```
