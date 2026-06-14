# Script di build per compilare il progetto Typst in PDF

$SourceFile = "src\main.typ"
# Il PDF finale viene generato nella root ed è committato: è il deliverable del progetto.
$OutputFile = "Report_Progetto11.pdf"

# 1. Controlla se Typst è installato
if (-not (Get-Command "typst" -ErrorAction SilentlyContinue)) {
    Write-Error "Errore: Typst non è installato o non è nel PATH."
    Write-Host "Puoi installarlo con: 'winget install typst'" -ForegroundColor Yellow
    exit 1
}

# 2. Compila il documento
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