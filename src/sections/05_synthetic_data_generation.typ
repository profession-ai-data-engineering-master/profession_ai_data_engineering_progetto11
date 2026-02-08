= Generazione dei dati sintetici con SDV

== Ambiente di esecuzione e setup (Google Colab)

Ho utilizzato Google Colab come ambiente di esecuzione per la generazione e la validazione dei dataset sintetici, per la semplicita' di setup, la disponibilita' di un ambiente Python preconfigurato e la facilita' di riproduzione del flusso.

Ho installato le dipendenze in celle dedicate, mantenendo la procedura allineata ai requisiti del progetto e senza modificare gli script. I comandi sono stati eseguiti in celle Google Colab usando esclusivamente la sintassi notebook. A livello documentale, il comando eseguito e' stato:

```
!pip install sdv pandas numpy pyarrow pytest pandera
```

Una volta installate le librerie, ho eseguito gli script senza alcuna modifica e ho validato i file generati tramite lo script di test di data quality e integrita' referenziale. Questa scelta rende il processo pienamente riproducibile: chiunque puo' rieseguire lo stesso flusso in Colab senza configurazioni locali complesse.

== Obiettivo della generazione dati sintetici

In questo step ho costruito una pipeline riproducibile per generare dati sintetici sanitari coerenti tra piu tabelle relazionali, usando SDV. Il mio obiettivo e' duplice: (1) ottenere dataset clinici, amministrativi e IoT consistenti tra loro, con vincoli di chiave rispettati; (2) produrre file pronti per le fasi successive di upload su S3 e ingestione in Snowflake. Ho scelto SDV per la capacita' di modellare relazioni multi-tabella e perche' consente di mantenere coerenza referenziale tra le entita' generate.

Le relazioni che devo preservare in modo deterministico sono:
- admissions.patient_id -> patients.patient_id
- admissions.ward_id -> wards.ward_id
- diagnoses.admission_id -> admissions.admission_id
- staff_assignments.staff_id -> staff.staff_id
- staff_assignments.ward_id -> wards.ward_id
- devices.ward_id -> wards.ward_id
- vital_signs.patient_id -> patients.patient_id
- vital_signs.device_id -> devices.device_id

Per garantire tale coerenza ho definito chiavi e relazioni fin dalla fase di seed, ho fatto addestrare il sintetizzatore su tabelle coerenti, e ho applicato controlli FK sia durante la generazione sia nel test di qualita'.

== Struttura del generatore dati (script Python)

Lo script di generazione che ho utilizzato e' uno strumento completo e standalone. L'ho progettato per essere eseguibile sia da riga di comando sia in ambienti notebook, con parametri espliciti per formato di output, scala di campionamento e seed randomico. Di seguito riporto lo script completo, invariato.
In particolare, lo script e' progettato come CLI standalone e, in ambiente Google Colab, lo invoco tramite `main([...])` per evitare conflitti con `argv` del kernel Jupyter.

=== Configurazione e parametri (CLI: out-dir, format, scale, seed)

Ho previsto una sezione di configurazione con `argparse` per rendere la pipeline riproducibile e controllabile. In particolare:
- `--out-dir` definisce la cartella di output, utile per mantenere la stessa struttura attesa dalle fasi successive.
- `--format` consente di scegliere tra CSV e Parquet, utile per ottimizzare storage o velocita' di ingestione.
- `--scale` controlla la dimensione del dataset sintetico rispetto al seed.
- `--seed` fissa il generatore randomico per garantire riproducibilita'.

=== Generazione seed controllati (tabelle e vincoli PK/FK)

Ho generato tabelle seed con valori controllati e dimensioni definite, in modo da avere una base consistente per l'addestramento. In questa fase ho imposto in modo esplicito i vincoli PK e le FK necessarie, creando chiavi con pattern deterministici (`make_ids`) e usando campionamenti che preservano la presenza delle chiavi parent. Questo e' il punto in cui assicuro che le relazioni elencate siano costruite correttamente a monte.

=== Rilevamento metadata SDV e training del sintetizzatore

Ho utilizzato `Metadata.detect_from_dataframes` per far inferire a SDV lo schema e le relazioni dai seed, evitando duplicazioni manuali e assicurando che i vincoli siano coerenti con i dati reali di input. Ho poi addestrato il sintetizzatore `HMASynthesizer`, scelto per la capacita' di gestire strutture multi-tabella con dipendenze relazionali.

=== Sampling dei dati sintetici

Ho campionato i dati sintetici con `sample(scale=...)`, ottenendo dataset proporzionali al seed. Subito dopo ho applicato `enforce_admission_order` per garantire coerenza temporale tra `admit_ts` e `discharge_ts`, correggendo automaticamente eventuali inversioni generate dal modello.

=== Validazione integrita' referenziale (FK) e controlli principali

Nello stesso script di generazione ho incluso una validazione FK minima tramite `validate_synthetic_tables`. Questo controllo intercetta eventuali orfani prima dell'export e verifica in modo esplicito tutte le relazioni richieste, evitando la propagazione di dataset inconsistenti verso le fasi successive.

=== Esportazione dei dataset (CSV/Parquet) e struttura output

Ho esportato i dati in una struttura di cartelle coerente con le sorgenti (ehr, erp, iot). Questo layout facilita il caricamento su S3 e l'ingestione in Snowflake, mantenendo la separazione logica dei domini e riducendo la complessita' del mapping successivo.

```py
"""
Generate synthetic healthcare datasets using SDV.

This script is a standalone generator for multi-table healthcare data.
It builds controlled in-memory seed tables, detects SDV metadata,
trains an HMA synthesizer, samples synthetic tables, validates FK integrity,
and exports datasets in CSV or Parquet format.

High-level flow:
1) Build or load seed tables (real_tables)
2) Detect SDV multi-table metadata + relationships
3) Fit a multi-table synthesizer (HMA)
4) Sample synthetic tables
5) Validate FK integrity
6) Export datasets (CSV or Parquet)
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Dict, Iterable

import numpy as np
import pandas as pd

# SDV version for logging
import sdv
# SDV imports (installed via requirements.txt)
from sdv.metadata import Metadata
from sdv.multi_table import HMASynthesizer


# ----------------------------
# Configuration / CLI
# ----------------------------
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments that control output paths, format, scale, and seed."""
    p = argparse.ArgumentParser(description="Generate synthetic healthcare datasets with SDV.")
    p.add_argument("--out-dir", default="out", help="Output directory (default: out)")
    p.add_argument("--format", choices=["csv", "parquet"], default="csv", help="Export format")
    p.add_argument("--scale", type=float, default=2.0, help="Sampling scale factor (default: 2.0)")
    p.add_argument("--seed", type=int, default=42, help="Random seed (default: 42)")
    return p.parse_args(argv)


# ----------------------------
# Seed / input tables
# ----------------------------
def build_seed_tables(rng: np.random.Generator) -> Dict[str, pd.DataFrame]:
    """
    Build controlled in-memory seed tables for SDV training.

    Returns:
        Dict[str, DataFrame]: Seed tables for patients, admissions, diagnoses,
        wards, staff, staff_assignments, devices, vital_signs.

    Assumptions:
        Each table includes its PK and the required FKs listed below.
      admissions.patient_id -> patients.patient_id
      admissions.ward_id -> wards.ward_id
      diagnoses.admission_id -> admissions.admission_id
      staff_assignments.staff_id -> staff.staff_id
      staff_assignments.ward_id -> wards.ward_id
      devices.ward_id -> wards.ward_id
      vital_signs.patient_id -> patients.patient_id
      vital_signs.device_id -> devices.device_id
    """
    # Configuration (row counts)
    n_wards = 10
    n_patients = 200
    n_staff = 60
    n_assignments = 120
    n_devices = 30
    n_admissions = 400
    n_diagnoses = 500
    n_vitals = 2000

    # Date ranges
    admissions_start = pd.Timestamp("2024-01-01")
    admissions_end = pd.Timestamp("2026-12-31")
    vitals_start = pd.Timestamp("2025-01-01")
    vitals_end = pd.Timestamp("2026-12-31")
    birth_start = pd.Timestamp("1950-01-01")
    birth_end = pd.Timestamp("2010-12-31")
    hire_start = pd.Timestamp("2010-01-01")
    hire_end = pd.Timestamp("2024-12-31")

    def make_ids(prefix: str, count: int, width: int) -> list[str]:
        return [f"{prefix}{i:0{width}d}" for i in range(1, count + 1)]

    def random_dates(start: pd.Timestamp, end: pd.Timestamp, count: int) -> pd.Series:
        start_ns = start.value
        end_ns = end.value
        values = rng.integers(start_ns, end_ns, size=count, dtype=np.int64)
        return pd.Series(pd.to_datetime(values))

    # Wards
    ward_ids = make_ids("W", n_wards, 3)
    ward_names = [f"Ward {i:02d}" for i in range(1, n_wards + 1)]
    specialties = rng.choice(
        ["Cardiology", "Neurology", "Oncology", "Pediatrics", "Emergency", "ICU", "Orthopedics"],
        size=n_wards,
        replace=True,
    )
    wards = pd.DataFrame({
        "ward_id": ward_ids,
        "ward_name": ward_names,
        "specialty": specialties,
    })

    # Patients
    patient_ids = make_ids("P", n_patients, 6)
    patients = pd.DataFrame({
        "patient_id": patient_ids,
        "sex": rng.choice(["F", "M"], size=n_patients),
        "birth_date": random_dates(birth_start, birth_end, n_patients).dt.date,
        "city": rng.choice(["Milan", "Rome", "Turin", "Naples", "Bologna", "Florence"], size=n_patients),
    })

    # Staff
    staff_ids = make_ids("S", n_staff, 5)
    staff = pd.DataFrame({
        "staff_id": staff_ids,
        "role": rng.choice(["Nurse", "Doctor", "Technician", "Therapist"], size=n_staff),
        "hire_date": random_dates(hire_start, hire_end, n_staff).dt.date,
    })

    # Staff assignments
    assignment_ids = make_ids("ASG", n_assignments, 6)
    staff_assignments = pd.DataFrame({
        "assignment_id": assignment_ids,
        "staff_id": rng.choice(staff_ids, size=n_assignments, replace=True),
        "ward_id": rng.choice(ward_ids, size=n_assignments, replace=True),
        "shift": rng.choice(["Day", "Night", "Evening"], size=n_assignments),
    })

    # Devices
    device_ids = make_ids("D", n_devices, 5)
    devices = pd.DataFrame({
        "device_id": device_ids,
        "ward_id": rng.choice(ward_ids, size=n_devices, replace=True),
        "device_type": rng.choice(["ECG", "PulseOx", "BP Monitor", "Thermometer"], size=n_devices),
    })

    # Admissions
    admission_ids = make_ids("ADM", n_admissions, 7)
    admit_ts = random_dates(admissions_start, admissions_end, n_admissions)
    length_days = rng.integers(1, 15, size=n_admissions, dtype=np.int64)
    discharge_ts = admit_ts + pd.to_timedelta(length_days, unit="D")
    admissions = pd.DataFrame({
        "admission_id": admission_ids,
        "patient_id": rng.choice(patient_ids, size=n_admissions, replace=True),
        "ward_id": rng.choice(ward_ids, size=n_admissions, replace=True),
        "admit_ts": admit_ts,
        "discharge_ts": discharge_ts,
    })

    # Diagnoses
    diagnosis_ids = make_ids("DX", n_diagnoses, 7)
    diagnoses = pd.DataFrame({
        "diagnosis_id": diagnosis_ids,
        "admission_id": rng.choice(admission_ids, size=n_diagnoses, replace=True),
        "icd10_code": rng.choice(["I10", "E11", "J18", "K21", "M54", "N39"], size=n_diagnoses),
        "severity": rng.choice(["low", "medium", "high"], size=n_diagnoses, p=[0.5, 0.35, 0.15]),
    })

    # Vital signs
    measurement_ids = make_ids("VS", n_vitals, 7)
    vital_signs = pd.DataFrame({
        "measurement_id": measurement_ids,
        "patient_id": rng.choice(patient_ids, size=n_vitals, replace=True),
        "device_id": rng.choice(device_ids, size=n_vitals, replace=True),
        "measured_at": random_dates(vitals_start, vitals_end, n_vitals),
        "heart_rate": rng.integers(50, 120, size=n_vitals),
        "spo2": rng.integers(90, 100, size=n_vitals),
        "systolic_bp": rng.integers(95, 160, size=n_vitals),
        "diastolic_bp": rng.integers(60, 100, size=n_vitals),
    })

    return {
        "wards": wards,
        "patients": patients,
        "staff": staff,
        "staff_assignments": staff_assignments,
        "devices": devices,
        "admissions": admissions,
        "diagnoses": diagnoses,
        "vital_signs": vital_signs,
    }


# ----------------------------
# Validation helpers
# ----------------------------
def assert_fk(child_df: pd.DataFrame, child_fk: str, parent_df: pd.DataFrame, parent_pk: str, rel_name: str) -> None:
    """Ensure all child FK values exist in the parent PK; raise with examples on failure."""
    missing = set(child_df[child_fk].dropna().astype(str)) - set(parent_df[parent_pk].dropna().astype(str))
    if missing:
        examples = list(missing)[:5]
        raise ValueError(f"[FK FAIL] {rel_name}: {len(missing)} orphan values. Examples: {examples}")


# ----------------------------
# SDV pipeline
# ----------------------------
def build_metadata(real_tables: Dict[str, pd.DataFrame], metadata_path: Path) -> Metadata:
    """
    Detect and persist SDV metadata from seed tables.

    The metadata is inferred from the input dataframes and saved to disk
    to make the generation pipeline auditable and repeatable.
    """
    if metadata_path.exists():
        metadata_path.unlink()
    metadata = Metadata.detect_from_dataframes(data=real_tables)
    metadata.save_to_json(metadata_path)
    return Metadata.load_from_json(metadata_path)


def fit_and_sample(
    real_tables: Dict[str, pd.DataFrame],
    metadata: Metadata,
    scale: float,
) -> Dict[str, pd.DataFrame]:
    """Fit an HMA synthesizer and return synthetic tables scaled from the seed."""
    synthesizer = HMASynthesizer(metadata)
    synthesizer.fit(real_tables)
    return synthesizer.sample(scale=scale)


def enforce_admission_order(tables: Dict[str, pd.DataFrame], rng: np.random.Generator) -> None:
    """Ensure discharge_ts is not earlier than admit_ts by correcting invalid rows."""
    admissions = tables.get("admissions")
    if admissions is None or admissions.empty:
        return

    admit_ts = pd.to_datetime(admissions["admit_ts"], errors="coerce")
    discharge_ts = pd.to_datetime(admissions["discharge_ts"], errors="coerce")
    invalid = admit_ts.notna() & discharge_ts.notna() & (discharge_ts < admit_ts)
    if invalid.any():
        offsets = rng.integers(1, 15, size=int(invalid.sum()), dtype=np.int64)
        discharge_ts.loc[invalid] = admit_ts.loc[invalid] + pd.to_timedelta(offsets, unit="D")
        admissions["discharge_ts"] = discharge_ts


def validate_synthetic_tables(tables: Dict[str, pd.DataFrame]) -> None:
    """Validate required FK relationships across generated tables."""
    # FK checks for required relationships
    assert_fk(tables["admissions"], "patient_id", tables["patients"], "patient_id", "admissions->patients")
    assert_fk(tables["admissions"], "ward_id", tables["wards"], "ward_id", "admissions->wards")
    assert_fk(tables["diagnoses"], "admission_id", tables["admissions"], "admission_id", "diagnoses->admissions")
    assert_fk(tables["staff_assignments"], "staff_id", tables["staff"], "staff_id", "staff_assignments->staff")
    assert_fk(tables["staff_assignments"], "ward_id", tables["wards"], "ward_id", "staff_assignments->wards")
    assert_fk(tables["devices"], "ward_id", tables["wards"], "ward_id", "devices->wards")
    assert_fk(tables["vital_signs"], "patient_id", tables["patients"], "patient_id", "vital_signs->patients")
    assert_fk(tables["vital_signs"], "device_id", tables["devices"], "device_id", "vital_signs->devices")


# ----------------------------
# Export
# ----------------------------
def export_tables(tables: Dict[str, pd.DataFrame], out_dir: Path, fmt: str) -> None:
    """Export tables to the standard ehr/erp/iot folder layout in CSV or Parquet."""
    # Create folders (same layout used by downstream ingestion)
    ehr_dir = out_dir / "ehr"
    erp_dir = out_dir / "erp"
    iot_dir = out_dir / "iot"
    ehr_dir.mkdir(parents=True, exist_ok=True)
    erp_dir.mkdir(parents=True, exist_ok=True)
    iot_dir.mkdir(parents=True, exist_ok=True)

    mapping = {
        "patients": ehr_dir / "patients",
        "admissions": ehr_dir / "admissions",
        "diagnoses": ehr_dir / "diagnoses",
        "wards": erp_dir / "wards",
        "staff": erp_dir / "staff",
        "staff_assignments": erp_dir / "staff_assignments",
        "devices": iot_dir / "devices",
        "vital_signs": iot_dir / "vital_signs",
    }

    for table_name, base_path in mapping.items():
        df = tables[table_name]
        if fmt == "csv":
            df.to_csv(f"{base_path}.csv", index=False)
        else:
            # Parquet needs pyarrow installed
            df.to_parquet(f"{base_path}.parquet", index=False)

    print(f"Export completed in: {out_dir.resolve()}")


def log_table_counts(label: str, tables: Dict[str, pd.DataFrame], order: Iterable[str]) -> None:
    """Print row counts for tables in a stable, explicit order."""
    print(f"{label} row counts:")
    for name in order:
        print(f"- {name}: {len(tables[name])}")


# ----------------------------
# Main
# ----------------------------
def main(argv: list[str] | None = None) -> int:
    """Run the end-to-end SDV generation pipeline."""
    args = parse_args(argv)
    rng = np.random.default_rng(args.seed)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"SDV version: {sdv.__version__}")

    table_order = [
        "wards",
        "patients",
        "staff",
        "staff_assignments",
        "devices",
        "admissions",
        "diagnoses",
        "vital_signs",
    ]

    # 1) Seed tables
    real_tables = build_seed_tables(rng)
    log_table_counts("Seed", real_tables, table_order)

    # 2) Metadata (detect)
    metadata_path = out_dir / "metadata.json"
    metadata = build_metadata(real_tables, metadata_path)

    # 3) Fit + sample
    synthetic_tables = fit_and_sample(real_tables, metadata, scale=args.scale)
    enforce_admission_order(synthetic_tables, rng)
    log_table_counts("Synthetic", synthetic_tables, table_order)

    # 4) Validate
    validate_synthetic_tables(synthetic_tables)
    print("FK integrity validated.")

    # 5) Export
    export_tables(synthetic_tables, out_dir, fmt=args.format)
    return 0

main(["--out-dir", "out", "--format", "csv", "--scale", "2.0", "--seed", "42"])
```

== Validazione data quality (script di test)

Per garantire che i dataset generati siano utilizzabili nelle fasi successive ho creato un secondo script di test che applica controlli sistematici di qualita' e di integrita' referenziale. L'approccio e' intenzionalmente separato dal generatore: in questo modo posso eseguire i test come gate di qualita' indipendente, prima di caricare i file su S3 e prima dell'ingestione in Snowflake.
I test sono stati eseguiti direttamente in Google Colab, invocando lo script di validazione in cella per far partire il flusso dei controlli.

=== Lettura file prodotti (CSV/Parquet)

Ho implementato una funzione di lettura che preferisce Parquet quando presente e ricade su CSV in caso contrario. Questo garantisce flessibilita' e compatibilita' con la fase di export e con eventuali evoluzioni del formato.

=== Controllo esistenza file attesi

Ho definito l'elenco dei path attesi per ogni tabella e verifico l'esistenza dei file prima di procedere. Se manca anche un solo dataset, il test fallisce immediatamente e richiede di rigenerare i dati.

=== Verifica PK (not null, unique)

Ho implementato una funzione generica `assert_pk` che controlla tre condizioni: presenza della colonna PK, assenza di valori null, assenza di duplicati. Questo assicura l'identificabilita' univoca delle entita'.

=== Verifica FK (no orphans) con esempi di violazioni

Per ciascuna relazione definita in `FKS` verifico che non esistano orfani. In caso di violazione, il test riporta il numero di chiavi orfane e un insieme di esempi, facilitando la diagnosi. Le relazioni controllate coincidono con quelle elencate a inizio capitolo e con quelle imposte nel generatore.

=== Verifica vincoli di dominio e range

Ho definito schemi `pandera` per controllare range temporali (birth_date, hire_date, measured_at) e valori plausibili per i parametri vitali (heart_rate, spo2, blood pressure). Ho inoltre vincolato gli insiemi ammessi per `severity`, `sex`, `shift`, `device_type`, `icd10_code`, `specialty`. Questi controlli rendono esplicite le direttive di qualita' e garantiscono coerenza semantica oltre alla sola integrita' referenziale.

=== Esecuzione del test e criterio di pass/fail

Ho impostato il criterio di pass/fail in modo rigoroso: qualsiasi violazione dei vincoli PK/FK, dei range o dei domini genera una `AssertionError` con esempi. In assenza di errori, considero i dataset pronti per il caricamento su S3 e per la successiva ingestione in Snowflake.
Durante l'esecuzione compare un FutureWarning di Pandera noto, che non impatta l'esito dei test; posso eliminarlo importando `pandera.pandas as pa` oppure impostando `DISABLE_PANDERA_IMPORT_WARNING=True`.

```py
"""
Validate data quality and referential integrity for synthetic datasets.

This test module verifies file presence, primary key constraints,
foreign key integrity, and domain/range checks for all generated tables.
"""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Tuple

import pandas as pd
import pandera.pandas as pa
from pandera import Check
import os

def get_out_dir() -> Path:
    """
    Resolve the output directory for generated datasets.

    - In repo/pytest runs: __file__ exists -> resolve relative to project structure.
    - In notebooks (Colab): __file__ is undefined -> default to current working dir.
    - Can be overridden via env var SYNTH_OUT_DIR.
    """
    override = os.getenv("SYNTH_OUT_DIR")
    if override:
        return Path(override).expanduser().resolve()

    try:
        # Works when running as a .py file (pytest, python test_*.py)
        project_root = Path(__file__).resolve().parents[1]
        return (project_root / "out").resolve()
    except NameError:
        # Works in notebooks (Colab/Jupyter)
        return (Path.cwd() / "out").resolve()

OUT_DIR = get_out_dir()


TABLE_PATHS: Dict[str, Path] = {
    "patients": OUT_DIR / "ehr" / "patients",
    "admissions": OUT_DIR / "ehr" / "admissions",
    "diagnoses": OUT_DIR / "ehr" / "diagnoses",
    "wards": OUT_DIR / "erp" / "wards",
    "staff": OUT_DIR / "erp" / "staff",
    "staff_assignments": OUT_DIR / "erp" / "staff_assignments",
    "devices": OUT_DIR / "iot" / "devices",
    "vital_signs": OUT_DIR / "iot" / "vital_signs",
}

PKS: Dict[str, str] = {
    "patients": "patient_id",
    "admissions": "admission_id",
    "diagnoses": "diagnosis_id",
    "wards": "ward_id",
    "staff": "staff_id",
    "staff_assignments": "assignment_id",
    "devices": "device_id",
    "vital_signs": "measurement_id",
}

FKS: List[Tuple[str, str, str, str]] = [
    ("admissions", "patient_id", "patients", "patient_id"),
    ("admissions", "ward_id", "wards", "ward_id"),
    ("diagnoses", "admission_id", "admissions", "admission_id"),
    ("staff_assignments", "staff_id", "staff", "staff_id"),
    ("staff_assignments", "ward_id", "wards", "ward_id"),
    ("devices", "ward_id", "wards", "ward_id"),
    ("vital_signs", "patient_id", "patients", "patient_id"),
    ("vital_signs", "device_id", "devices", "device_id"),
]


def load_table(base_path: Path) -> pd.DataFrame:
    """Load a table from Parquet or CSV, preferring Parquet when available."""
    parquet_path = base_path.with_suffix(".parquet")
    csv_path = base_path.with_suffix(".csv")

    if parquet_path.exists():
        return pd.read_parquet(parquet_path)
    if csv_path.exists():
        return pd.read_csv(csv_path)

    raise FileNotFoundError(
        f"Missing dataset file for '{base_path.name}'. Expected {parquet_path.name} or {csv_path.name}."
    )


def load_all_tables() -> Dict[str, pd.DataFrame]:
    """Load all expected tables from the out/ directory."""
    if not OUT_DIR.exists():
        raise AssertionError("Missing out/ directory. Run generate_synthetic_data.py first.")

    tables: Dict[str, pd.DataFrame] = {}
    for name, path in TABLE_PATHS.items():
        tables[name] = load_table(path)
    return tables


def assert_pk(df: pd.DataFrame, table_name: str, pk: str) -> None:
    """Validate PK presence, non-nullness, and uniqueness for a table."""
    if pk not in df.columns:
        raise AssertionError(f"{table_name}: missing primary key column '{pk}'.")

    null_count = df[pk].isna().sum()
    if null_count:
        raise AssertionError(f"{table_name}: primary key '{pk}' has {null_count} null values.")

    duplicated = df[df[pk].duplicated()][pk]
    if not duplicated.empty:
        examples = duplicated.head(5).tolist()
        raise AssertionError(
            f"{table_name}: primary key '{pk}' has duplicates. Examples: {examples}"
        )


def assert_fk(child: pd.DataFrame, child_fk: str, parent: pd.DataFrame, parent_pk: str, rel: str) -> None:
    """Validate that all child FK values exist in the parent PK."""
    missing = set(child[child_fk].dropna().astype(str)) - set(parent[parent_pk].dropna().astype(str))
    if missing:
        examples = list(missing)[:5]
        raise AssertionError(f"FK FAIL {rel}: {len(missing)} orphan values. Examples: {examples}")


def build_schemas() -> Dict[str, pa.DataFrameSchema]:
    """Build Pandera schemas enforcing domain, range, and type constraints."""
    date_1950 = pd.Timestamp("1950-01-01")
    date_2010 = pd.Timestamp("2010-12-31")
    date_2010_start = pd.Timestamp("2010-01-01")
    date_2024_end = pd.Timestamp("2024-12-31")
    date_2025_start = pd.Timestamp("2025-01-01")
    date_2026_end = pd.Timestamp("2026-12-31")

    return {
        "wards": pa.DataFrameSchema(
            {
                "ward_id": pa.Column(str),
                "ward_name": pa.Column(str),
                "specialty": pa.Column(str, Check.isin({
                    "Cardiology",
                    "Neurology",
                    "Oncology",
                    "Pediatrics",
                    "Emergency",
                    "ICU",
                    "Orthopedics",
                })),
            }
        ),
        "patients": pa.DataFrameSchema(
            {
                "patient_id": pa.Column(str),
                "sex": pa.Column(str, Check.isin({"F", "M"})),
                "birth_date": pa.Column(
                    pa.DateTime,
                    Check.between(date_1950, date_2010),
                    coerce=True,
                ),
                "city": pa.Column(str),
            }
        ),
        "staff": pa.DataFrameSchema(
            {
                "staff_id": pa.Column(str),
                "role": pa.Column(str),
                "hire_date": pa.Column(
                    pa.DateTime,
                    Check.between(date_2010_start, date_2024_end),
                    coerce=True,
                ),
            }
        ),
        "staff_assignments": pa.DataFrameSchema(
            {
                "assignment_id": pa.Column(str),
                "staff_id": pa.Column(str),
                "ward_id": pa.Column(str),
                "shift": pa.Column(str, Check.isin({"Day", "Night", "Evening"})),
            }
        ),
        "devices": pa.DataFrameSchema(
            {
                "device_id": pa.Column(str),
                "ward_id": pa.Column(str),
                "device_type": pa.Column(str, Check.isin({"ECG", "PulseOx", "BP Monitor", "Thermometer"})),
            }
        ),
        "admissions": pa.DataFrameSchema(
            {
                "admission_id": pa.Column(str),
                "patient_id": pa.Column(str),
                "ward_id": pa.Column(str),
                "admit_ts": pa.Column(pa.DateTime, coerce=True),
                "discharge_ts": pa.Column(pa.DateTime, coerce=True),
            }
        ),
        "diagnoses": pa.DataFrameSchema(
            {
                "diagnosis_id": pa.Column(str),
                "admission_id": pa.Column(str),
                "icd10_code": pa.Column(str, Check.isin({"I10", "E11", "J18", "K21", "M54", "N39"})),
                "severity": pa.Column(str, Check.isin({"low", "medium", "high"})),
            }
        ),
        "vital_signs": pa.DataFrameSchema(
            {
                "measurement_id": pa.Column(str),
                "patient_id": pa.Column(str),
                "device_id": pa.Column(str),
                "measured_at": pa.Column(
                    pa.DateTime,
                    Check.between(date_2025_start, date_2026_end),
                    coerce=True,
                ),
                "heart_rate": pa.Column(int, Check.between(50, 120)),
                "spo2": pa.Column(int, Check.between(90, 100)),
                "systolic_bp": pa.Column(int, Check.between(95, 160)),
                "diastolic_bp": pa.Column(int, Check.between(60, 100)),
            }
        ),
    }


def test_files_exist() -> None:
    """Fail fast if any expected dataset file is missing."""
    if not OUT_DIR.exists():
        raise AssertionError("Missing out/ directory. Run generate_synthetic_data.py first.")

    missing: List[str] = []
    for name, base in TABLE_PATHS.items():
        if not base.with_suffix(".parquet").exists() and not base.with_suffix(".csv").exists():
            missing.append(name)

    if missing:
        raise AssertionError(
            "Missing dataset files for tables: " + ", ".join(missing) + ". Run generate_synthetic_data.py first."
        )


def test_primary_keys() -> None:
    """Check PK constraints for all tables."""
    tables = load_all_tables()
    for table_name, pk in PKS.items():
        assert_pk(tables[table_name], table_name, pk)


def test_foreign_keys_integrity() -> None:
    """Check FK integrity for all declared relationships."""
    tables = load_all_tables()
    for child, child_fk, parent, parent_pk in FKS:
        assert_fk(tables[child], child_fk, tables[parent], parent_pk, f"{child}.{child_fk}->{parent}.{parent_pk}")


def test_domain_constraints() -> None:
    """Validate domain/range constraints and temporal consistency."""
    tables = load_all_tables()
    schemas = build_schemas()

    for table_name, schema in schemas.items():
        try:
            schema.validate(tables[table_name], lazy=True)
        except pa.errors.SchemaErrors as exc:
            failure = exc.failure_cases.head(5)
            raise AssertionError(
                f"{table_name}: domain constraints failed. Examples:\n{failure}"
            ) from exc

    admissions = tables["admissions"].copy()
    admissions["admit_ts"] = pd.to_datetime(admissions["admit_ts"], errors="coerce")
    admissions["discharge_ts"] = pd.to_datetime(admissions["discharge_ts"], errors="coerce")
    invalid_admissions = admissions[admissions["admit_ts"] > admissions["discharge_ts"]]
    if not invalid_admissions.empty:
        examples = invalid_admissions[["admission_id", "admit_ts", "discharge_ts"]].head(5)
        raise AssertionError(
            "admissions: admit_ts must be <= discharge_ts. Examples:\n" + examples.to_string(index=False)
        )

if __name__ == "__main__":
    test_files_exist()
    test_primary_keys()
    test_foreign_keys_integrity()
    test_domain_constraints()
    print("ALL DATA QUALITY TESTS PASSED")

```

== Risultato finale e collegamento alle fasi successive (S3/Snowflake)

Al termine del processo ho ottenuto dataset sintetici coerenti, validati e strutturati per sorgente (ehr, erp, iot), pronti per l'upload su S3 e l'ingestione in Snowflake. La generazione e la validazione sono riproducibili grazie al seed fissato e ai test automatizzati, e la coerenza relazionale e' garantita sia dal modello SDV sia dai controlli FK e dai vincoli di dominio.