# Script di build per compilare il progetto Typst in PDF

$SourceFile = "src\main.typ"
$BuildDir = "build"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutputFile = "$BuildDir\Report_Progetto11_$Timestamp.pdf"

# 1. Crea la cartella build se non esiste
if (-not (Test-Path -Path $BuildDir)) {
    Write-Host "Creazione cartella '$BuildDir'..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $BuildDir | Out-Null
} else {
    # Svuota la cartella build mantenendo la directory
    Write-Host "Svuotamento cartella '$BuildDir'..." -ForegroundColor Cyan
    try {
        Get-ChildItem -Path $BuildDir -Force | Remove-Item -Force -Recurse
    } catch {
        Write-Error "Errore durante lo svuotamento della cartella '$BuildDir': $_"
        exit 1
    }
}

# 2. Controlla se Typst è installato
if (-not (Get-Command "typst" -ErrorAction SilentlyContinue)) {
    Write-Error "Errore: Typst non è installato o non è nel PATH."
    Write-Host "Puoi installarlo con: 'winget install typst'" -ForegroundColor Yellow
    exit 1
}

# 3. Compila il documento
Write-Host "Compilazione di $SourceFile in corso..." -ForegroundColor Cyan
try {
    # --root . imposta la root del progetto alla cartella corrente, 
    # permettendo import relativi corretti
    typst compile "$SourceFile" "$OutputFile" --root .
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Build completata con SUCCESSO!" -ForegroundColor Green
        Write-Host "PDF generato in: $OutputFile" -ForegroundColor Green
    } else {
        Write-Error "Errore durante la compilazione."
        exit $LASTEXITCODE
    }
} catch {
    Write-Error "Si è verificato un errore inatteso: $_"
    exit 1
}