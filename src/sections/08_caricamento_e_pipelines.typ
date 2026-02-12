= Caricamento dati e pipeline

== Obiettivo

In questa sezione descrivo e documento il processo operativo di caricamento e trasformazione dati su Snowflake, a partire da file *Parquet* nel Data Lake su Amazon S3.
Il processo è *uno solo*, verificabile end-to-end, ed è eseguito esclusivamente tramite *TASK chain* che invoca tre procedure SQL con `EXECUTE AS OWNER`:

*S3 → stage esterno → RAW (COPY INTO) → CURATED (quarantena + MERGE) → ANALYTICS (MERGE) → orchestrazione con task chain*.

In Snowflake i vincoli PK/FK sono *informational* (non enforced): l'integrità logica e la qualità vengono garantite dalla pipeline tramite:

- ordine di esecuzione;
- quarantena dei record non conformi;
- deduplica deterministica tramite `ROW_NUMBER()` con `QUALIFY = 1` sulle business key `ID_*`;
- `MERGE` idempotenti su business key nei layer `CURATED` e `ANALYTICS`.

L'intero flusso opera nel perimetro RBAC definito in Sezione 7:

- esecuzione con `ROLE_DATA_ENGINEER`;
- ingestione su `WH_INGEST`;
- trasformazioni su `WH_OPERATIONS`;
- pubblicazione su `WH_ANALYTICS`.

Le query manuali presenti in questa sezione sono *solo evidenze di verifica* (listing, history, riconciliazioni, monitoring) e non rappresentano un flusso alternativo.

== Ingestione e staging

L'ingestione avviene in modalità *pull* da S3 tramite *Storage Integration* e stage esterno, senza credenziali statiche e con *least privilege*.

*A) Bucket S3 e struttura prefix*

Il Data Lake risiede su Amazon S3 (regione `eu-central-1`) con bucket privato e *Block Public Access* attivo:

- Bucket: `healthcare-data-prod-eu`
- Base path: `s3://healthcare-data-prod-eu/snowflake/raw/`
- Prefix per domini:
  - `ehr/` (es. `ehr/pazienti/`, `ehr/ricoveri/`)
  - `erp/` (es. `erp/reparti/`)
  - `iot/` (es. `iot/dispositivi/`, `iot/parametri_vitali/`)

*B) IAM Role + policy (least privilege)*

L'accesso cross-account da Snowflake a S3 utilizza un ruolo IAM dedicato:

- Role: `snowflake_s3_readonly_role`
- Policy: `snowflake_s3_raw_read_policy` con soli privilegi `s3:ListBucket` e `s3:GetObject` sulle risorse:
  - `arn:aws:s3:::healthcare-data-prod-eu`
  - `arn:aws:s3:::healthcare-data-prod-eu/snowflake/raw/*`

*C) Storage Integration e trust policy (cross-account)*

La *Storage Integration* è un oggetto di account e viene creata con privilegi amministrativi.

#figure(
	```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE STORAGE INTEGRATION s3_int_healthcare_data
	TYPE = EXTERNAL_STAGE
	STORAGE_PROVIDER = S3
	ENABLED = TRUE
	STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake_s3_readonly_role'
	STORAGE_ALLOWED_LOCATIONS = ('s3://healthcare-data-prod-eu/snowflake/raw/');
```,
	caption: "Creazione Storage Integration per accesso a S3"
)

I parametri necessari alla trust policy AWS vengono recuperati dall'integrazione:

#figure(
	```sql
DESC INTEGRATION s3_int_healthcare_data;
```,
	caption: "Recupero parametri per la trust policy (cross-account)"
)

Dal risultato si copiano i valori:

- `STORAGE_AWS_IAM_USER_ARN`
- `STORAGE_AWS_EXTERNAL_ID`

// Screenshot suggerito: 01_sf_desc_integration_s3_int.png

La trust policy del ruolo IAM utilizza questi due valori per prevenire *confused deputy*.

#figure(
	```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowSnowflakeAssumeRole",
			"Effect": "Allow",
			"Principal": {
				"AWS": "<STORAGE_AWS_IAM_USER_ARN_FROM_DESC>"
			},
			"Action": "sts:AssumeRole",
			"Condition": {
				"StringEquals": {
					"sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID_FROM_DESC>"
				}
			}
		}
	]
}
```,
	caption: "Trust policy del ruolo IAM (valori presi da DESC INTEGRATION)"
)

*D) File format Parquet e stage esterno*

File format e stage esterno sono creati nello schema `RAW` del database `HEALTHCARE_DW`.

#figure(
	```sql
USE ROLE SYSADMIN;
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.RAW;

CREATE OR REPLACE FILE FORMAT ff_parquet
	TYPE = PARQUET;

CREATE OR REPLACE STAGE stage_healthcare_raw
	URL = 's3://healthcare-data-prod-eu/snowflake/raw/'
	STORAGE_INTEGRATION = s3_int_healthcare_data
	FILE_FORMAT = ff_parquet;
```,
	caption: "Creazione file format Parquet e stage esterno su S3"
)

RBAC per l'esecuzione della pipeline con `ROLE_DATA_ENGINEER`: i grant sono riportati e organizzati nella sezione *Orchestrazione e scheduling* (blocchi *Grant strutturali* e *Grant runtime*), evitando duplicazioni.

*E) Verifica stage (evidenza di listing)*

Le evidenze operative sono `SHOW/DESC` e `LIST` sul prefix atteso.

```sql
SHOW STAGES LIKE 'STAGE_HEALTHCARE_RAW' IN SCHEMA HEALTHCARE_DW.RAW;
DESC STAGE HEALTHCARE_DW.RAW.stage_healthcare_raw;
```

// Screenshot suggerito: 02_sf_show_desc_stage_healthcare_raw.png

#figure(
	```sql
LIST @HEALTHCARE_DW.RAW.stage_healthcare_raw/ehr/pazienti/;
```,
	caption: "LIST dei file Parquet visibili su S3"
)

// Screenshot suggerito: 03_sf_list_stage_ehr_pazienti.png

== Pipeline ELT (flusso unico: task → procedure)

Il processo ELT è eseguito *solo* tramite task chain nello schema tecnico `HEALTHCARE_DW.PIPELINE`.
Le tre procedure sono idempotenti e vengono invocate in sequenza fissa:

1. `sp_load_raw()` → carica `RAW.*` con `COPY INTO` (fail-fast).
2. `sp_transform_curated()` → quarantena e popolamento `CURATED.*` esclusivamente via `MERGE`.
3. `sp_publish_analytics()` → popolamento `ANALYTICS.*` esclusivamente via `MERGE`.

Le query manuali non eseguono la pipeline: sono utilizzate solo per mostrare evidenze e controlli.

=== 1) RAW: sp_load_raw() (COPY INTO, fail-fast)

La procedura di ingestione usa `WH_INGEST` e carica le tabelle mirror nel layer `RAW`.
Ogni `COPY INTO` opera con `ON_ERROR = 'ABORT_STATEMENT'` per interrompere in modo deterministico su incompatibilità schema/file.

*Idempotenza file-level in RAW (comportamento di default di COPY INTO)*

`COPY INTO <table>` mantiene una *load history* per tabella: a parità di target (`RAW.*`) e path dello stage, Snowflake evita di ricaricare file già caricati (entro la finestra di retention della history).
Il reload degli stessi file può avvenire solo in casi operativi espliciti, ad esempio:

- uso di `FORCE = TRUE` nel `COPY INTO`;
- scadenza della load history (oltre la retention) e successiva riesecuzione;
- file effettivamente cambiato (nuovo oggetto/versione su S3) e considerato come “nuovo” per la history;
- cambio di target (un'altra tabella) o cambio del path/pattern dello stage.

Questa proprietà rende *difendibile* l'idempotenza *file-level* del layer `RAW` come comportamento operativo, ma va descritta in modo non assoluto: vale *a parità di tabella target*, *path/pattern dello stage* e *oggetto file* (file object) tracciato nella load history.
In pratica `RAW` funziona come *landing zone append-only* a livello file: `COPY INTO` tende a non ricaricare file già visti dalla history della specifica tabella, ma lo stesso contenuto può essere considerato “nuovo” (e quindi ricaricato) se:

- si usa `FORCE = TRUE` nel `COPY INTO`;
- cambia `path` o `pattern` di ingestione (diversa origine logica nella history);
- il file viene copiato/rinominato su S3 (nuovo object/key rispetto a quello storico);
- scade la retention della load history e successivamente si riesegue la procedura.

Per questo motivo l'idempotenza *logica* del dato (deduplica e consistenza sulle business key) non è demandata a `RAW`: è ottenuta in modo deterministico dai `MERGE` nei layer `CURATED` e `ANALYTICS`.

*Schema drift (colonne/tipi Parquet)*

Se lo schema dei file Parquet cambia (colonne aggiunte/rimosse o tipi diversi), il comportamento *fail-fast* con `ON_ERROR = 'ABORT_STATEMENT'` è voluto: impedisce di caricare dati potenzialmente corrotti o troncati.
Operativamente si procede così: si ispeziona lo schema dei nuovi file, si aggiorna il DDL delle tabelle `RAW.*` (es. `ALTER TABLE ... ADD COLUMN` o adeguamento tipi), e poi si riesegue la pipeline.
La quarantena e i `MERGE` in `CURATED` continuano a garantire integrità logica e dedup deterministica.

```sql
USE ROLE ROLE_DATA_ENGINEER;
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.PIPELINE;

CREATE OR REPLACE PROCEDURE sp_load_raw()
	RETURNS STRING
	LANGUAGE SQL
	EXECUTE AS OWNER
AS
$$
	COPY INTO HEALTHCARE_DW.RAW.PAZIENTI
	FROM @HEALTHCARE_DW.RAW.stage_healthcare_raw/ehr/pazienti/
	FILE_FORMAT = (TYPE = PARQUET)
	ON_ERROR = 'ABORT_STATEMENT';

	COPY INTO HEALTHCARE_DW.RAW.REPARTI
	FROM @HEALTHCARE_DW.RAW.stage_healthcare_raw/erp/reparti/
	FILE_FORMAT = (TYPE = PARQUET)
	ON_ERROR = 'ABORT_STATEMENT';

	COPY INTO HEALTHCARE_DW.RAW.DISPOSITIVI
	FROM @HEALTHCARE_DW.RAW.stage_healthcare_raw/iot/dispositivi/
	FILE_FORMAT = (TYPE = PARQUET)
	ON_ERROR = 'ABORT_STATEMENT';

	COPY INTO HEALTHCARE_DW.RAW.RICOVERI
	FROM @HEALTHCARE_DW.RAW.stage_healthcare_raw/ehr/ricoveri/
	FILE_FORMAT = (TYPE = PARQUET)
	ON_ERROR = 'ABORT_STATEMENT';

	COPY INTO HEALTHCARE_DW.RAW.PARAMETRI_VITALI
	FROM @HEALTHCARE_DW.RAW.stage_healthcare_raw/iot/parametri_vitali/
	FILE_FORMAT = (TYPE = PARQUET)
	ON_ERROR = 'ABORT_STATEMENT';

	RETURN 'OK';
$$;
```

// Screenshot suggerito: 04_sf_create_procedure_sp_load_raw.png

*Evidenza: tracciabilità file-level dell'ingestione (COPY_HISTORY)*

```sql
USE DATABASE HEALTHCARE_DW;

SELECT *
FROM TABLE(
	HEALTHCARE_DW.INFORMATION_SCHEMA.COPY_HISTORY(
		TABLE_NAME => 'RAW.PAZIENTI',
		START_TIME => DATEADD('day', -1, CURRENT_TIMESTAMP())
	)
)
ORDER BY LAST_LOAD_TIME DESC;
```

// Screenshot suggerito: 05_sf_copy_history_raw_pazienti.png

*Evidenza: idempotenza file-level (nessun reload a parità di input, senza FORCE)*

Questa query raggruppa per `FILE_NAME` e permette di verificare che, rieseguendo `sp_load_raw()` a parità di input e senza `FORCE`, il numero di load per file non incrementi.

```sql
USE DATABASE HEALTHCARE_DW;

SELECT
	FILE_NAME,
	COUNT(*) AS N_LOADS,
	MIN(LAST_LOAD_TIME) AS FIRST_LOAD_TIME,
	MAX(LAST_LOAD_TIME) AS LAST_LOAD_TIME
FROM TABLE(
	HEALTHCARE_DW.INFORMATION_SCHEMA.COPY_HISTORY(
		TABLE_NAME => 'RAW.PAZIENTI',
		START_TIME => DATEADD('day', -7, CURRENT_TIMESTAMP())
	)
)
GROUP BY FILE_NAME
ORDER BY N_LOADS DESC, LAST_LOAD_TIME DESC;
```

// Screenshot suggerito: 05b_sf_copy_history_idempotence_raw_pazienti.png

==== Natura del layer RAW

Il layer `RAW` è una *landing zone* tecnica e *append-only*:

- non applica deduplicazione *row-level*;
- può contenere più record con la stessa business key (es. stesso `ID_*`) provenienti da file diversi e/o da run diversi;
- rappresenta lo *storico tecnico di ingestione* (mirror dei file caricati), non uno stato “pulito” del dominio;
- la deduplica deterministica e l'idempotenza logica sulle business key sono applicate *solo* in `CURATED` (e propagate in `ANALYTICS`).

=== 2) CURATED: sp_transform_curated() (quarantena + MERGE, idempotente)

Il layer `CURATED` viene popolato esclusivamente via `MERGE` sulle business key.
Le anomalie (chiavi nulle e/o riferimenti orfani) vengono isolate solo tramite `INSERT` nelle tabelle `*_QUARANTENA`.

*Nota operativa (snapshot quarantena, non storico)*

Le tabelle `*_QUARANTENA` sono *snapshot* dell'ultima esecuzione: vengono `TRUNCATE` a ogni run e poi ricalcolate in modo deterministico.
Lo storico degli eventi di quarantena è fuori scope in questo progetto; in produzione si implementerebbe un audit separato (es. tabella append-only con `run_id`/timestamp di esecuzione), senza alterare lo schema funzionale delle tabelle di layer.

La deduplica è deterministica e applicata sempre con:

- `ROW_NUMBER()` con `QUALIFY = 1`, partizionando sulla business key `ID_*` e usando un `ORDER BY` deterministico.

Ho applicato sempre un ordinamento deterministico coerente con il dominio:

- `CURATED.PAZIENTI`: fingerprint su `CODICE_FISCALE`, `NOME`, `COGNOME`, `SESSO`, `DATA_NASCITA`, `GRUPPO_SANGUIGNO`, `CITTA`, `INDIRIZZO`, `CAP`, `PAESE`, `EMAIL`, `TELEFONO`, `PIANO_ASSICURATIVO`, `ID_ASSICURAZIONE`.
- `CURATED.REPARTI`: fingerprint su `NOME_REPARTO`, `SPECIALITA`.
- `CURATED.RICOVERI`: ordinamento per `DATA_RICOVERO` (evento) e, a parità, fingerprint su `ID_PAZIENTE`, `ID_REPARTO`, `DATA_RICOVERO`, `DATA_DIMISSIONE`, `DURATA_DEGENZA_GIORNI`, `TIPO_RICOVERO`, `PROVENIENZA_RICOVERO`, `ESITO_DIMISSIONE`.
- `CURATED.PARAMETRI_VITALI`: ordinamento per `DATA_MISURAZIONE` (evento) e, a parità, fingerprint su `ID_PAZIENTE`, `ID_DISPOSITIVO`, `DATA_MISURAZIONE`, `FREQUENZA_CARDIACA`, `SATURAZIONE_OSSIGENO`, `PRESSIONE_SISTOLICA`, `PRESSIONE_DIASTOLICA`, `TEMPERATURA_C`, `FREQUENZA_RESPIRATORIA`, `GLICEMIA_MG_DL`.

Ordine operativo della procedura (integrità logica):

a) `TRUNCATE` delle tabelle `*_QUARANTENA` (snapshot per run);
b) `MERGE CURATED.PAZIENTI`;
c) `MERGE CURATED.REPARTI`;
d) quarantena `RICOVERI` (LEFT JOIN verso `CURATED.PAZIENTI` e `CURATED.REPARTI`);
e) `MERGE CURATED.RICOVERI` (join valido verso `CURATED.PAZIENTI` e `CURATED.REPARTI`);
f) quarantena `PARAMETRI_VITALI` (LEFT JOIN verso `CURATED.PAZIENTI` e `RAW.DISPOSITIVI`);
g) `MERGE CURATED.PARAMETRI_VITALI` (join valido verso `CURATED.PAZIENTI` e `RAW.DISPOSITIVI`).

*Nota architetturale su `RAW.DISPOSITIVI` come dominio FK*

Nel progetto `DISPOSITIVI` è *reference data tecnica* e non viene trasformata in `CURATED`: il layer `RAW.DISPOSITIVI` è quindi il dominio di validazione della FK `ID_DISPOSITIVO` per `PARAMETRI_VITALI`.
Questa scelta è coerente con l'architettura: si mantiene la normalizzazione e la qualità referenziale dove serve (validazione FK), senza introdurre trasformazioni aggiuntive non previste dal modello.

==== Setup strutture CURATED (eseguito una sola volta)

Le strutture dei layer `CURATED` e `*_QUARANTENA` vengono create in fase di *setup* (provisioning) e non fanno parte della logica operativa della pipeline.
Le procedure eseguono esclusivamente trasformazioni e DML (`TRUNCATE`, `INSERT`, `MERGE`): questo separa il provisioning infrastrutturale dalla logica di caricamento.

```sql
USE ROLE ROLE_DATA_ENGINEER;
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.CURATED;

CREATE TABLE IF NOT EXISTS HEALTHCARE_DW.CURATED.PAZIENTI LIKE HEALTHCARE_DW.RAW.PAZIENTI;
CREATE TABLE IF NOT EXISTS HEALTHCARE_DW.CURATED.REPARTI LIKE HEALTHCARE_DW.RAW.REPARTI;
CREATE TABLE IF NOT EXISTS HEALTHCARE_DW.CURATED.RICOVERI LIKE HEALTHCARE_DW.RAW.RICOVERI;
CREATE TABLE IF NOT EXISTS HEALTHCARE_DW.CURATED.PARAMETRI_VITALI LIKE HEALTHCARE_DW.RAW.PARAMETRI_VITALI;

CREATE TABLE IF NOT EXISTS HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA LIKE HEALTHCARE_DW.RAW.RICOVERI;
CREATE TABLE IF NOT EXISTS HEALTHCARE_DW.CURATED.PARAMETRI_VITALI_QUARANTENA LIKE HEALTHCARE_DW.RAW.PARAMETRI_VITALI;
```

```sql
USE ROLE ROLE_DATA_ENGINEER;
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.PIPELINE;

CREATE OR REPLACE PROCEDURE sp_transform_curated()
	RETURNS STRING
	LANGUAGE SQL
	EXECUTE AS OWNER
AS
$$
	-- a) Quarantena come snapshot per run
	-- MUST-FIX: idempotenza quarantena (stesso RAW => stessa quarantena, niente crescita per rerun)
	TRUNCATE TABLE HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA;
	-- MUST-FIX: idempotenza quarantena (stesso RAW => stessa quarantena, niente crescita per rerun)
	TRUNCATE TABLE HEALTHCARE_DW.CURATED.PARAMETRI_VITALI_QUARANTENA;

	-- b) MERGE CURATED.PAZIENTI (dedup deterministica su ID_PAZIENTE)
	MERGE INTO HEALTHCARE_DW.CURATED.PAZIENTI t
	USING (
		SELECT
			r.ID_PAZIENTE,
			r.CODICE_FISCALE,
			r.NOME,
			r.COGNOME,
			r.SESSO,
			r.DATA_NASCITA,
			r.STATO_CIVILE,
			r.LINGUA_PRIMARIA,
			r.GRUPPO_SANGUIGNO,
			r.CITTA,
			r.INDIRIZZO,
			r.CAP,
			r.PAESE,
			r.EMAIL,
			r.TELEFONO,
			r.COMPAGNIA_ASSICURATIVA,
			r.PIANO_ASSICURATIVO,
			r.ID_ASSICURAZIONE,
			r.CONTATTO_EMERGENZA_NOME,
			r.CONTATTO_EMERGENZA_TELEFONO,
			r.ALTEZZA_CM,
			r.PESO_KG
		FROM HEALTHCARE_DW.RAW.PAZIENTI r
		WHERE r.ID_PAZIENTE IS NOT NULL
		QUALIFY ROW_NUMBER() OVER (
			PARTITION BY r.ID_PAZIENTE
			ORDER BY MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'CODICE_FISCALE', r.CODICE_FISCALE,
						'NOME', r.NOME,
						'COGNOME', r.COGNOME,
						'SESSO', r.SESSO,
						'DATA_NASCITA', r.DATA_NASCITA,
						'GRUPPO_SANGUIGNO', r.GRUPPO_SANGUIGNO,
						'CITTA', r.CITTA,
						'INDIRIZZO', r.INDIRIZZO,
						'CAP', r.CAP,
						'PAESE', r.PAESE,
						'EMAIL', r.EMAIL,
						'TELEFONO', r.TELEFONO,
						'PIANO_ASSICURATIVO', r.PIANO_ASSICURATIVO,
						'ID_ASSICURAZIONE', r.ID_ASSICURAZIONE
					)
				)
			) DESC
		) = 1
	) s
	ON t.ID_PAZIENTE = s.ID_PAZIENTE
	WHEN MATCHED THEN UPDATE SET
		CODICE_FISCALE = s.CODICE_FISCALE,
		NOME = s.NOME,
		COGNOME = s.COGNOME,
		SESSO = s.SESSO,
		DATA_NASCITA = s.DATA_NASCITA,
		STATO_CIVILE = s.STATO_CIVILE,
		LINGUA_PRIMARIA = s.LINGUA_PRIMARIA,
		GRUPPO_SANGUIGNO = s.GRUPPO_SANGUIGNO,
		CITTA = s.CITTA,
		INDIRIZZO = s.INDIRIZZO,
		CAP = s.CAP,
		PAESE = s.PAESE,
		EMAIL = s.EMAIL,
		TELEFONO = s.TELEFONO,
		COMPAGNIA_ASSICURATIVA = s.COMPAGNIA_ASSICURATIVA,
		PIANO_ASSICURATIVO = s.PIANO_ASSICURATIVO,
		ID_ASSICURAZIONE = s.ID_ASSICURAZIONE,
		CONTATTO_EMERGENZA_NOME = s.CONTATTO_EMERGENZA_NOME,
		CONTATTO_EMERGENZA_TELEFONO = s.CONTATTO_EMERGENZA_TELEFONO,
		ALTEZZA_CM = s.ALTEZZA_CM,
		PESO_KG = s.PESO_KG
	WHEN NOT MATCHED THEN INSERT (
		ID_PAZIENTE,
		CODICE_FISCALE,
		NOME,
		COGNOME,
		SESSO,
		DATA_NASCITA,
		STATO_CIVILE,
		LINGUA_PRIMARIA,
		GRUPPO_SANGUIGNO,
		CITTA,
		INDIRIZZO,
		CAP,
		PAESE,
		EMAIL,
		TELEFONO,
		COMPAGNIA_ASSICURATIVA,
		PIANO_ASSICURATIVO,
		ID_ASSICURAZIONE,
		CONTATTO_EMERGENZA_NOME,
		CONTATTO_EMERGENZA_TELEFONO,
		ALTEZZA_CM,
		PESO_KG
	)
	VALUES (
		s.ID_PAZIENTE,
		s.CODICE_FISCALE,
		s.NOME,
		s.COGNOME,
		s.SESSO,
		s.DATA_NASCITA,
		s.STATO_CIVILE,
		s.LINGUA_PRIMARIA,
		s.GRUPPO_SANGUIGNO,
		s.CITTA,
		s.INDIRIZZO,
		s.CAP,
		s.PAESE,
		s.EMAIL,
		s.TELEFONO,
		s.COMPAGNIA_ASSICURATIVA,
		s.PIANO_ASSICURATIVO,
		s.ID_ASSICURAZIONE,
		s.CONTATTO_EMERGENZA_NOME,
		s.CONTATTO_EMERGENZA_TELEFONO,
		s.ALTEZZA_CM,
		s.PESO_KG
	);

	-- c) MERGE CURATED.REPARTI (dedup deterministica su ID_REPARTO)
	MERGE INTO HEALTHCARE_DW.CURATED.REPARTI t
	USING (
		SELECT
			r.ID_REPARTO,
			r.NOME_REPARTO,
			r.SPECIALITA
		FROM HEALTHCARE_DW.RAW.REPARTI r
		WHERE r.ID_REPARTO IS NOT NULL
		QUALIFY ROW_NUMBER() OVER (
			PARTITION BY r.ID_REPARTO
			ORDER BY MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'NOME_REPARTO', r.NOME_REPARTO,
						'SPECIALITA', r.SPECIALITA
					)
				)
			) DESC
		) = 1
	) s
	ON t.ID_REPARTO = s.ID_REPARTO
	WHEN MATCHED THEN UPDATE SET
		NOME_REPARTO = s.NOME_REPARTO,
		SPECIALITA = s.SPECIALITA
	WHEN NOT MATCHED THEN INSERT (ID_REPARTO, NOME_REPARTO, SPECIALITA)
	VALUES (s.ID_REPARTO, s.NOME_REPARTO, s.SPECIALITA);

	-- d) Quarantena RICOVERI: PK/FK NULL e/o orfani (LEFT JOIN verso CURATED)
	-- MUST-FIX: quarantena deduplicata e deterministica (business key + fallback key su PK NULL)
	INSERT INTO HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA
	SELECT q.* EXCLUDE (QUARANTINE_KEY, ROW_FINGERPRINT)
	FROM (
		SELECT
			r.*,
			COALESCE(
				TO_VARCHAR(r.ID_RICOVERO),
				MD5(
					TO_VARCHAR(
						OBJECT_CONSTRUCT_KEEP_NULL(
							'ID_RICOVERO', r.ID_RICOVERO,
							'ID_PAZIENTE', r.ID_PAZIENTE,
							'ID_REPARTO', r.ID_REPARTO,
							'DATA_RICOVERO', r.DATA_RICOVERO,
							'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
							'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
							'TIPO_RICOVERO', r.TIPO_RICOVERO,
							'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
							'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
						)
					)
				)
			) AS QUARANTINE_KEY,
			MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'ID_PAZIENTE', r.ID_PAZIENTE,
						'ID_REPARTO', r.ID_REPARTO,
						'DATA_RICOVERO', r.DATA_RICOVERO,
						'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
						'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
						'TIPO_RICOVERO', r.TIPO_RICOVERO,
						'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
						'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
					)
				)
			) AS ROW_FINGERPRINT
		FROM HEALTHCARE_DW.RAW.RICOVERI r
		LEFT JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
			ON r.ID_PAZIENTE = p.ID_PAZIENTE
		LEFT JOIN HEALTHCARE_DW.CURATED.REPARTI rep
			ON r.ID_REPARTO = rep.ID_REPARTO
		WHERE r.ID_RICOVERO IS NULL
			OR r.ID_PAZIENTE IS NULL
			OR r.ID_REPARTO IS NULL
			OR p.ID_PAZIENTE IS NULL
			OR rep.ID_REPARTO IS NULL
	) q
	QUALIFY ROW_NUMBER() OVER (
		PARTITION BY q.QUARANTINE_KEY
		-- MUST-FIX: fallback timestamp coerente, deterministico e robusto (usa TRY_* per non fallire su formati non parseabili)
		ORDER BY COALESCE(
			TRY_TO_TIMESTAMP_NTZ(q.DATA_RICOVERO),
			TRY_TO_TIMESTAMP_NTZ(q.DATA_RICOVERO::STRING),
			TO_TIMESTAMP_NTZ('1900-01-01 00:00:00')
		) DESC,
		q.ROW_FINGERPRINT DESC
	) = 1;

	-- e) MERGE CURATED.RICOVERI (join valido verso CURATED.PAZIENTI + CURATED.REPARTI)
	MERGE INTO HEALTHCARE_DW.CURATED.RICOVERI t
	USING (
		SELECT
			r.ID_RICOVERO,
			r.ID_PAZIENTE,
			r.ID_REPARTO,
			r.DATA_RICOVERO,
			r.DATA_DIMISSIONE,
			r.DURATA_DEGENZA_GIORNI,
			r.TIPO_RICOVERO,
			r.PROVENIENZA_RICOVERO,
			r.ESITO_DIMISSIONE
		FROM HEALTHCARE_DW.RAW.RICOVERI r
		JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
			ON r.ID_PAZIENTE = p.ID_PAZIENTE
		JOIN HEALTHCARE_DW.CURATED.REPARTI rep
			ON r.ID_REPARTO = rep.ID_REPARTO
		WHERE r.ID_RICOVERO IS NOT NULL
			AND r.ID_PAZIENTE IS NOT NULL
			AND r.ID_REPARTO IS NOT NULL
		QUALIFY ROW_NUMBER() OVER (
			PARTITION BY r.ID_RICOVERO
			ORDER BY r.DATA_RICOVERO DESC,
				MD5(
					TO_VARCHAR(
						OBJECT_CONSTRUCT_KEEP_NULL(
							'ID_PAZIENTE', r.ID_PAZIENTE,
							'ID_REPARTO', r.ID_REPARTO,
							'DATA_RICOVERO', r.DATA_RICOVERO,
							'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
							'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
							'TIPO_RICOVERO', r.TIPO_RICOVERO,
							'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
							'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
						)
					)
				) DESC
		) = 1
	) s
	ON t.ID_RICOVERO = s.ID_RICOVERO
	WHEN MATCHED THEN UPDATE SET
		ID_PAZIENTE = s.ID_PAZIENTE,
		ID_REPARTO = s.ID_REPARTO,
		DATA_RICOVERO = s.DATA_RICOVERO,
		DATA_DIMISSIONE = s.DATA_DIMISSIONE,
		DURATA_DEGENZA_GIORNI = s.DURATA_DEGENZA_GIORNI,
		TIPO_RICOVERO = s.TIPO_RICOVERO,
		PROVENIENZA_RICOVERO = s.PROVENIENZA_RICOVERO,
		ESITO_DIMISSIONE = s.ESITO_DIMISSIONE
	WHEN NOT MATCHED THEN INSERT (
		ID_RICOVERO,
		ID_PAZIENTE,
		ID_REPARTO,
		DATA_RICOVERO,
		DATA_DIMISSIONE,
		DURATA_DEGENZA_GIORNI,
		TIPO_RICOVERO,
		PROVENIENZA_RICOVERO,
		ESITO_DIMISSIONE
	)
	VALUES (
		s.ID_RICOVERO,
		s.ID_PAZIENTE,
		s.ID_REPARTO,
		s.DATA_RICOVERO,
		s.DATA_DIMISSIONE,
		s.DURATA_DEGENZA_GIORNI,
		s.TIPO_RICOVERO,
		s.PROVENIENZA_RICOVERO,
		s.ESITO_DIMISSIONE
	);

	-- f) Quarantena PARAMETRI_VITALI: PK/FK NULL e/o orfani (LEFT JOIN verso CURATED.PAZIENTI e RAW.DISPOSITIVI)
	-- MUST-FIX: quarantena deduplicata e deterministica (business key + fallback key su PK NULL)
	INSERT INTO HEALTHCARE_DW.CURATED.PARAMETRI_VITALI_QUARANTENA
	SELECT q.* EXCLUDE (QUARANTINE_KEY, ROW_FINGERPRINT)
	FROM (
		SELECT
			v.*,
			COALESCE(
				TO_VARCHAR(v.ID_MISURAZIONE),
				MD5(
					TO_VARCHAR(
						OBJECT_CONSTRUCT_KEEP_NULL(
							'ID_MISURAZIONE', v.ID_MISURAZIONE,
							'ID_PAZIENTE', v.ID_PAZIENTE,
							'ID_DISPOSITIVO', v.ID_DISPOSITIVO,
							'DATA_MISURAZIONE', v.DATA_MISURAZIONE,
							'FREQUENZA_CARDIACA', v.FREQUENZA_CARDIACA,
							'SATURAZIONE_OSSIGENO', v.SATURAZIONE_OSSIGENO,
							'PRESSIONE_SISTOLICA', v.PRESSIONE_SISTOLICA,
							'PRESSIONE_DIASTOLICA', v.PRESSIONE_DIASTOLICA,
							'TEMPERATURA_C', v.TEMPERATURA_C,
							'FREQUENZA_RESPIRATORIA', v.FREQUENZA_RESPIRATORIA,
							'GLICEMIA_MG_DL', v.GLICEMIA_MG_DL
						)
					)
				)
			) AS QUARANTINE_KEY,
			MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'ID_PAZIENTE', v.ID_PAZIENTE,
						'ID_DISPOSITIVO', v.ID_DISPOSITIVO,
						'DATA_MISURAZIONE', v.DATA_MISURAZIONE,
						'FREQUENZA_CARDIACA', v.FREQUENZA_CARDIACA,
						'SATURAZIONE_OSSIGENO', v.SATURAZIONE_OSSIGENO,
						'PRESSIONE_SISTOLICA', v.PRESSIONE_SISTOLICA,
						'PRESSIONE_DIASTOLICA', v.PRESSIONE_DIASTOLICA,
						'TEMPERATURA_C', v.TEMPERATURA_C,
						'FREQUENZA_RESPIRATORIA', v.FREQUENZA_RESPIRATORIA,
						'GLICEMIA_MG_DL', v.GLICEMIA_MG_DL
					)
				)
			) AS ROW_FINGERPRINT
		FROM HEALTHCARE_DW.RAW.PARAMETRI_VITALI v
		LEFT JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
			ON v.ID_PAZIENTE = p.ID_PAZIENTE
		LEFT JOIN HEALTHCARE_DW.RAW.DISPOSITIVI d
			ON v.ID_DISPOSITIVO = d.ID_DISPOSITIVO
		WHERE v.ID_MISURAZIONE IS NULL
			OR v.ID_PAZIENTE IS NULL
			OR v.ID_DISPOSITIVO IS NULL
			OR p.ID_PAZIENTE IS NULL
			OR d.ID_DISPOSITIVO IS NULL
	) q
	QUALIFY ROW_NUMBER() OVER (
		PARTITION BY q.QUARANTINE_KEY
		-- MUST-FIX: fallback timestamp coerente, deterministico e robusto (usa TRY_* per non fallire su formati non parseabili)
		ORDER BY COALESCE(
			TRY_TO_TIMESTAMP_NTZ(q.DATA_MISURAZIONE),
			TRY_TO_TIMESTAMP_NTZ(q.DATA_MISURAZIONE::STRING),
			TO_TIMESTAMP_NTZ('1900-01-01 00:00:00')
		) DESC,
		q.ROW_FINGERPRINT DESC
	) = 1;

	-- g) MERGE CURATED.PARAMETRI_VITALI (join valido verso CURATED.PAZIENTI + RAW.DISPOSITIVI)
	MERGE INTO HEALTHCARE_DW.CURATED.PARAMETRI_VITALI t
	USING (
		SELECT
			v.ID_MISURAZIONE,
			v.ID_PAZIENTE,
			v.ID_DISPOSITIVO,
			v.DATA_MISURAZIONE,
			v.FREQUENZA_CARDIACA,
			v.SATURAZIONE_OSSIGENO,
			v.PRESSIONE_SISTOLICA,
			v.PRESSIONE_DIASTOLICA,
			v.TEMPERATURA_C,
			v.FREQUENZA_RESPIRATORIA,
			v.GLICEMIA_MG_DL
		FROM HEALTHCARE_DW.RAW.PARAMETRI_VITALI v
		JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
			ON v.ID_PAZIENTE = p.ID_PAZIENTE
		JOIN HEALTHCARE_DW.RAW.DISPOSITIVI d
			ON v.ID_DISPOSITIVO = d.ID_DISPOSITIVO
		WHERE v.ID_MISURAZIONE IS NOT NULL
			AND v.ID_PAZIENTE IS NOT NULL
			AND v.ID_DISPOSITIVO IS NOT NULL
		QUALIFY ROW_NUMBER() OVER (
			PARTITION BY v.ID_MISURAZIONE
			ORDER BY v.DATA_MISURAZIONE DESC,
				MD5(
					TO_VARCHAR(
						OBJECT_CONSTRUCT_KEEP_NULL(
							'ID_PAZIENTE', v.ID_PAZIENTE,
							'ID_DISPOSITIVO', v.ID_DISPOSITIVO,
							'DATA_MISURAZIONE', v.DATA_MISURAZIONE,
							'FREQUENZA_CARDIACA', v.FREQUENZA_CARDIACA,
							'SATURAZIONE_OSSIGENO', v.SATURAZIONE_OSSIGENO,
							'PRESSIONE_SISTOLICA', v.PRESSIONE_SISTOLICA,
							'PRESSIONE_DIASTOLICA', v.PRESSIONE_DIASTOLICA,
							'TEMPERATURA_C', v.TEMPERATURA_C,
							'FREQUENZA_RESPIRATORIA', v.FREQUENZA_RESPIRATORIA,
							'GLICEMIA_MG_DL', v.GLICEMIA_MG_DL
						)
					)
				) DESC
		) = 1
	) s
	ON t.ID_MISURAZIONE = s.ID_MISURAZIONE
	WHEN MATCHED THEN UPDATE SET
		ID_PAZIENTE = s.ID_PAZIENTE,
		ID_DISPOSITIVO = s.ID_DISPOSITIVO,
		DATA_MISURAZIONE = s.DATA_MISURAZIONE,
		FREQUENZA_CARDIACA = s.FREQUENZA_CARDIACA,
		SATURAZIONE_OSSIGENO = s.SATURAZIONE_OSSIGENO,
		PRESSIONE_SISTOLICA = s.PRESSIONE_SISTOLICA,
		PRESSIONE_DIASTOLICA = s.PRESSIONE_DIASTOLICA,
		TEMPERATURA_C = s.TEMPERATURA_C,
		FREQUENZA_RESPIRATORIA = s.FREQUENZA_RESPIRATORIA,
		GLICEMIA_MG_DL = s.GLICEMIA_MG_DL
	WHEN NOT MATCHED THEN INSERT (
		ID_MISURAZIONE,
		ID_PAZIENTE,
		ID_DISPOSITIVO,
		DATA_MISURAZIONE,
		FREQUENZA_CARDIACA,
		SATURAZIONE_OSSIGENO,
		PRESSIONE_SISTOLICA,
		PRESSIONE_DIASTOLICA,
		TEMPERATURA_C,
		FREQUENZA_RESPIRATORIA,
		GLICEMIA_MG_DL
	)
	VALUES (
		s.ID_MISURAZIONE,
		s.ID_PAZIENTE,
		s.ID_DISPOSITIVO,
		s.DATA_MISURAZIONE,
		s.FREQUENZA_CARDIACA,
		s.SATURAZIONE_OSSIGENO,
		s.PRESSIONE_SISTOLICA,
		s.PRESSIONE_DIASTOLICA,
		s.TEMPERATURA_C,
		s.FREQUENZA_RESPIRATORIA,
		s.GLICEMIA_MG_DL
	);

	RETURN 'OK';
$$;
```

// Screenshot suggerito: 06_sf_create_procedure_sp_transform_curated.png

*Evidenza: tabelle CURATED e QUARANTENA esistono*

```sql
SHOW TABLES LIKE '%QUARANTENA%' IN SCHEMA HEALTHCARE_DW.CURATED;
SHOW TABLES IN SCHEMA HEALTHCARE_DW.CURATED;
```

// Screenshot suggerito: 07_sf_curated_tables_and_quarantine_exist.png

*Evidenza: conteggi quarantena vs curated (senza numeri inventati)*

```sql
SELECT 'CURATED.RICOVERI' AS table_name, COUNT(*) AS n
FROM HEALTHCARE_DW.CURATED.RICOVERI
UNION ALL
SELECT 'CURATED.RICOVERI_QUARANTENA', COUNT(*)
FROM HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA
UNION ALL
SELECT 'CURATED.PARAMETRI_VITALI', COUNT(*)
FROM HEALTHCARE_DW.CURATED.PARAMETRI_VITALI
UNION ALL
SELECT 'CURATED.PARAMETRI_VITALI_QUARANTENA', COUNT(*)
FROM HEALTHCARE_DW.CURATED.PARAMETRI_VITALI_QUARANTENA;
```

// Screenshot suggerito: 08_sf_quarantine_vs_curated_counts.png

==== Riconciliazione logica del layer CURATED

La riconciliazione basata su `RAW = CURATED + QUARANTENA` è *fragile* perché ignora un insieme previsto dal design: i record *validi ma duplicati* sulla business key (`ID_RICOVERO`) che vengono *scartati deterministamente* dalla dedup (`ROW_NUMBER() ... QUALIFY = 1`).
In altre parole, un `delta_should_be_zero` può risultare diverso da zero anche quando la pipeline funziona correttamente.

La metrica corretta separa tre insiemi logici:

- *INVALID_RAW_RICOVERI*: PK/FK null e/o FK orfane → confluiscono in `CURATED.RICOVERI_QUARANTENA` (snapshot deduplicata).
- *VALID_CANDIDATES_RAW_RICOVERI*: record RAW che passano i check PK/FK e join verso `CURATED.PAZIENTI` e `CURATED.REPARTI` → candidati al `MERGE`.
- *DEDUP_DROPPED_VALID_RICOVERI*: record validi scartati perché non sono la riga `rn = 1` per lo stesso `ID_RICOVERO`.

Di conseguenza, per i `RICOVERI` vale la scomposizione difendibile:

`RAW (invalidi) → QUARANTENA`  *e*  `RAW (validi) → CURATED + scartati da dedup`.

*Evidenza 1: scomposizione insiemi (conteggi) + coerenza con snapshot quarantena*

```sql
WITH raw_invalid AS (
	SELECT r.*
	FROM HEALTHCARE_DW.RAW.RICOVERI r
	LEFT JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
		ON r.ID_PAZIENTE = p.ID_PAZIENTE
	LEFT JOIN HEALTHCARE_DW.CURATED.REPARTI rep
		ON r.ID_REPARTO = rep.ID_REPARTO
	WHERE r.ID_RICOVERO IS NULL
		OR r.ID_PAZIENTE IS NULL
		OR r.ID_REPARTO IS NULL
		OR p.ID_PAZIENTE IS NULL
		OR rep.ID_REPARTO IS NULL
),
raw_invalid_dedup_quarantine AS (
	SELECT q.* EXCLUDE (quarantine_key, row_fingerprint)
	FROM (
		SELECT
			r.*,
			COALESCE(
				TO_VARCHAR(r.ID_RICOVERO),
				MD5(
					TO_VARCHAR(
						OBJECT_CONSTRUCT_KEEP_NULL(
							'ID_RICOVERO', r.ID_RICOVERO,
							'ID_PAZIENTE', r.ID_PAZIENTE,
							'ID_REPARTO', r.ID_REPARTO,
							'DATA_RICOVERO', r.DATA_RICOVERO,
							'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
							'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
							'TIPO_RICOVERO', r.TIPO_RICOVERO,
							'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
							'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
						)
					)
				)
			) AS quarantine_key,
			MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'ID_PAZIENTE', r.ID_PAZIENTE,
						'ID_REPARTO', r.ID_REPARTO,
						'DATA_RICOVERO', r.DATA_RICOVERO,
						'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
						'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
						'TIPO_RICOVERO', r.TIPO_RICOVERO,
						'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
						'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
					)
				)
			) AS row_fingerprint
		FROM raw_invalid r
	) q
	QUALIFY ROW_NUMBER() OVER (
		PARTITION BY q.quarantine_key
		ORDER BY COALESCE(
			TRY_TO_TIMESTAMP_NTZ(q.DATA_RICOVERO),
			TRY_TO_TIMESTAMP_NTZ(q.DATA_RICOVERO::STRING),
			TO_TIMESTAMP_NTZ('1900-01-01 00:00:00')
		) DESC,
		q.row_fingerprint DESC
	) = 1
),
raw_valid_candidates AS (
	SELECT r.*
	FROM HEALTHCARE_DW.RAW.RICOVERI r
	JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
		ON r.ID_PAZIENTE = p.ID_PAZIENTE
	JOIN HEALTHCARE_DW.CURATED.REPARTI rep
		ON r.ID_REPARTO = rep.ID_REPARTO
	WHERE r.ID_RICOVERO IS NOT NULL
		AND r.ID_PAZIENTE IS NOT NULL
		AND r.ID_REPARTO IS NOT NULL
),
raw_valid_ranked AS (
	SELECT
		r.*,
		ROW_NUMBER() OVER (
			PARTITION BY r.ID_RICOVERO
			ORDER BY COALESCE(
				TRY_TO_TIMESTAMP_NTZ(r.DATA_RICOVERO),
				TRY_TO_TIMESTAMP_NTZ(r.DATA_RICOVERO::STRING),
				TO_TIMESTAMP_NTZ('1900-01-01 00:00:00')
			) DESC,
			MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'ID_PAZIENTE', r.ID_PAZIENTE,
						'ID_REPARTO', r.ID_REPARTO,
						'DATA_RICOVERO', r.DATA_RICOVERO,
						'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
						'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
						'TIPO_RICOVERO', r.TIPO_RICOVERO,
						'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
						'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
					)
				)
			) DESC
		) AS rn
	FROM raw_valid_candidates r
),
dedup_dropped_valid AS (
	SELECT *
	FROM raw_valid_ranked
	WHERE rn > 1
)
SELECT
	(SELECT COUNT(*) FROM HEALTHCARE_DW.RAW.RICOVERI) AS raw_total,
	(SELECT COUNT(*) FROM raw_invalid) AS invalid_raw_rows,
	(SELECT COUNT(*) FROM raw_invalid_dedup_quarantine) AS invalid_raw_dedup_expected_quarantine,
	(SELECT COUNT(*) FROM HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA) AS curated_quarantine_rows,
	(SELECT COUNT(*) FROM raw_valid_candidates) AS valid_candidates_raw_rows,
	(SELECT COUNT(*) FROM raw_valid_ranked WHERE rn = 1) AS valid_kept_by_dedup_expected_curated,
	(SELECT COUNT(*) FROM dedup_dropped_valid) AS dedup_dropped_valid_rows,
	(SELECT COUNT(*) FROM HEALTHCARE_DW.CURATED.RICOVERI) AS curated_ricoveri_rows;
```

// Screenshot suggerito: 08d_sf_reconciliation_sets_ricoveri.png

*Evidenza 2: CURATED contiene al massimo 1 record per business key*

```sql
SELECT ID_RICOVERO, COUNT(*) AS n
FROM HEALTHCARE_DW.CURATED.RICOVERI
GROUP BY ID_RICOVERO
HAVING COUNT(*) > 1;
```

// Screenshot suggerito: 08e_sf_curated_no_duplicates_ricoveri.png

*Evidenza 3: esempi di record validi scartati dalla dedup (non sono quarantena)*

```sql
WITH raw_valid_candidates AS (
	SELECT r.*
	FROM HEALTHCARE_DW.RAW.RICOVERI r
	JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
		ON r.ID_PAZIENTE = p.ID_PAZIENTE
	JOIN HEALTHCARE_DW.CURATED.REPARTI rep
		ON r.ID_REPARTO = rep.ID_REPARTO
	WHERE r.ID_RICOVERO IS NOT NULL
		AND r.ID_PAZIENTE IS NOT NULL
		AND r.ID_REPARTO IS NOT NULL
),
raw_valid_ranked AS (
	SELECT
		r.ID_RICOVERO,
		r.ID_PAZIENTE,
		r.ID_REPARTO,
		r.DATA_RICOVERO,
		r.DATA_DIMISSIONE,
		ROW_NUMBER() OVER (
			PARTITION BY r.ID_RICOVERO
			ORDER BY COALESCE(
				TRY_TO_TIMESTAMP_NTZ(r.DATA_RICOVERO),
				TRY_TO_TIMESTAMP_NTZ(r.DATA_RICOVERO::STRING),
				TO_TIMESTAMP_NTZ('1900-01-01 00:00:00')
			) DESC,
			MD5(
				TO_VARCHAR(
					OBJECT_CONSTRUCT_KEEP_NULL(
						'ID_PAZIENTE', r.ID_PAZIENTE,
						'ID_REPARTO', r.ID_REPARTO,
						'DATA_RICOVERO', r.DATA_RICOVERO,
						'DATA_DIMISSIONE', r.DATA_DIMISSIONE,
						'DURATA_DEGENZA_GIORNI', r.DURATA_DEGENZA_GIORNI,
						'TIPO_RICOVERO', r.TIPO_RICOVERO,
						'PROVENIENZA_RICOVERO', r.PROVENIENZA_RICOVERO,
						'ESITO_DIMISSIONE', r.ESITO_DIMISSIONE
					)
				)
			) DESC
		) AS rn
	FROM raw_valid_candidates r
)
SELECT *
FROM raw_valid_ranked
WHERE rn > 1
ORDER BY ID_RICOVERO, rn
LIMIT 20;
```

// Screenshot suggerito: 08f_sf_dedup_dropped_valid_ricoveri.png

_Nota_: lo stesso approccio di scomposizione (invalidi → quarantena, validi → curated + scartati da dedup) è applicabile in modo simmetrico al dominio `PARAMETRI_VITALI` sostituendo chiavi, join di validazione e criterio di ordinamento/fingerprint come da procedura.

==== Motivi di quarantena (ricostruibili via query)

Le tabelle `*_QUARANTENA` non aggiungono colonne di audit: il *motivo* è ricostruibile in modo deterministico via query, classificando i record quarantinati in:

- `PK_NULL`
- `FK_NULL`
- `FK_ORFANA_*` verso le dimensioni richieste

*RICOVERI_QUARANTENA: classificazione motivo (evidenza)*

```sql
SELECT
	COALESCE(
		TO_VARCHAR(q.ID_RICOVERO),
		MD5(
			TO_VARCHAR(
				OBJECT_CONSTRUCT_KEEP_NULL(
					'ID_RICOVERO', q.ID_RICOVERO,
					'ID_PAZIENTE', q.ID_PAZIENTE,
					'ID_REPARTO', q.ID_REPARTO,
					'DATA_RICOVERO', q.DATA_RICOVERO,
					'DATA_DIMISSIONE', q.DATA_DIMISSIONE,
					'DURATA_DEGENZA_GIORNI', q.DURATA_DEGENZA_GIORNI,
					'TIPO_RICOVERO', q.TIPO_RICOVERO,
					'PROVENIENZA_RICOVERO', q.PROVENIENZA_RICOVERO,
					'ESITO_DIMISSIONE', q.ESITO_DIMISSIONE
				)
			)
		)
	) AS record_key,
	CASE
		WHEN q.ID_RICOVERO IS NULL THEN 'PK_NULL'
		WHEN q.ID_PAZIENTE IS NULL OR q.ID_REPARTO IS NULL THEN 'FK_NULL'
		WHEN p.ID_PAZIENTE IS NULL THEN 'FK_ORFANA_PAZIENTE'
		WHEN rep.ID_REPARTO IS NULL THEN 'FK_ORFANA_REPARTO'
		ELSE 'OTHER'
	END AS quarantine_reason,
	COUNT(*) AS n_records
FROM HEALTHCARE_DW.CURATED.RICOVERI_QUARANTENA q
LEFT JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
	ON q.ID_PAZIENTE = p.ID_PAZIENTE
LEFT JOIN HEALTHCARE_DW.CURATED.REPARTI rep
	ON q.ID_REPARTO = rep.ID_REPARTO
GROUP BY 1, 2
ORDER BY quarantine_reason, n_records DESC;
```

// Screenshot suggerito: 08b_sf_quarantine_reasons_ricoveri.png

*PARAMETRI_VITALI_QUARANTENA: classificazione motivo (evidenza)*

```sql
SELECT
	COALESCE(
		TO_VARCHAR(q.ID_MISURAZIONE),
		MD5(
			TO_VARCHAR(
				OBJECT_CONSTRUCT_KEEP_NULL(
					'ID_MISURAZIONE', q.ID_MISURAZIONE,
					'ID_PAZIENTE', q.ID_PAZIENTE,
					'ID_DISPOSITIVO', q.ID_DISPOSITIVO,
					'DATA_MISURAZIONE', q.DATA_MISURAZIONE,
					'FREQUENZA_CARDIACA', q.FREQUENZA_CARDIACA,
					'SATURAZIONE_OSSIGENO', q.SATURAZIONE_OSSIGENO,
					'PRESSIONE_SISTOLICA', q.PRESSIONE_SISTOLICA,
					'PRESSIONE_DIASTOLICA', q.PRESSIONE_DIASTOLICA,
					'TEMPERATURA_C', q.TEMPERATURA_C,
					'FREQUENZA_RESPIRATORIA', q.FREQUENZA_RESPIRATORIA,
					'GLICEMIA_MG_DL', q.GLICEMIA_MG_DL
				)
			)
		)
	) AS record_key,
	CASE
		WHEN q.ID_MISURAZIONE IS NULL THEN 'PK_NULL'
		WHEN q.ID_PAZIENTE IS NULL OR q.ID_DISPOSITIVO IS NULL THEN 'FK_NULL'
		WHEN p.ID_PAZIENTE IS NULL THEN 'FK_ORFANA_PAZIENTE'
		WHEN d.ID_DISPOSITIVO IS NULL THEN 'FK_ORFANA_DISPOSITIVO'
		ELSE 'OTHER'
	END AS quarantine_reason,
	COUNT(*) AS n_records
FROM HEALTHCARE_DW.CURATED.PARAMETRI_VITALI_QUARANTENA q
LEFT JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
	ON q.ID_PAZIENTE = p.ID_PAZIENTE
LEFT JOIN HEALTHCARE_DW.RAW.DISPOSITIVI d
	ON q.ID_DISPOSITIVO = d.ID_DISPOSITIVO
GROUP BY 1, 2
ORDER BY quarantine_reason, n_records DESC;
```

// Screenshot suggerito: 08c_sf_quarantine_reasons_parametri_vitali.png

=== 3) ANALYTICS: sp_publish_analytics() (solo MERGE, idempotente)

Le tabelle `ANALYTICS` sono create come da Sezione 6.
La procedura esegue esclusivamente `MERGE` idempotenti sulle business key, senza DDL e senza `INSERT` di popolamento.

Ordine operativo della procedura:

a) `MERGE DIM_PAZIENTE` e `MERGE DIM_REPARTO`;
b) `MERGE FACT_RICOVERI`;
c) `MERGE FACT_MISURAZIONI` con `ORA_GIORNO` derivata da `TS_MISURAZIONE`.

```sql
USE ROLE ROLE_DATA_ENGINEER;
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.PIPELINE;

CREATE OR REPLACE PROCEDURE sp_publish_analytics()
	RETURNS STRING
	LANGUAGE SQL
	EXECUTE AS OWNER
AS
$$
	-- a) DIM
	MERGE INTO HEALTHCARE_DW.ANALYTICS.DIM_PAZIENTE t
	USING (
		SELECT
			ID_PAZIENTE,
			SESSO,
			DATA_NASCITA,
			CITTA,
			GRUPPO_SANGUIGNO,
			PIANO_ASSICURATIVO
		FROM HEALTHCARE_DW.CURATED.PAZIENTI
	) s
	ON t.ID_PAZIENTE = s.ID_PAZIENTE
	WHEN MATCHED THEN UPDATE SET
		SESSO = s.SESSO,
		DATA_NASCITA = s.DATA_NASCITA,
		CITTA = s.CITTA,
		GRUPPO_SANGUIGNO = s.GRUPPO_SANGUIGNO,
		PIANO_ASSICURATIVO = s.PIANO_ASSICURATIVO
	WHEN NOT MATCHED THEN INSERT (ID_PAZIENTE, SESSO, DATA_NASCITA, CITTA, GRUPPO_SANGUIGNO, PIANO_ASSICURATIVO)
	VALUES (s.ID_PAZIENTE, s.SESSO, s.DATA_NASCITA, s.CITTA, s.GRUPPO_SANGUIGNO, s.PIANO_ASSICURATIVO);

	MERGE INTO HEALTHCARE_DW.ANALYTICS.DIM_REPARTO t
	USING (
		SELECT
			ID_REPARTO,
			NOME_REPARTO,
			SPECIALITA
		FROM HEALTHCARE_DW.CURATED.REPARTI
	) s
	ON t.ID_REPARTO = s.ID_REPARTO
	WHEN MATCHED THEN UPDATE SET
		NOME_REPARTO = s.NOME_REPARTO,
		SPECIALITA = s.SPECIALITA
	WHEN NOT MATCHED THEN INSERT (ID_REPARTO, NOME_REPARTO, SPECIALITA)
	VALUES (s.ID_REPARTO, s.NOME_REPARTO, s.SPECIALITA);

	-- b) FACT_RICOVERI
	MERGE INTO HEALTHCARE_DW.ANALYTICS.FACT_RICOVERI t
	USING (
		SELECT
			ID_RICOVERO,
			ID_PAZIENTE,
			ID_REPARTO,
			DATA_RICOVERO AS TS_RICOVERO,
			DATA_DIMISSIONE AS TS_DIMISSIONE,
			DURATA_DEGENZA_GIORNI,
			TIPO_RICOVERO,
			ESITO_DIMISSIONE
		FROM HEALTHCARE_DW.CURATED.RICOVERI
	) s
	ON t.ID_RICOVERO = s.ID_RICOVERO
	WHEN MATCHED THEN UPDATE SET
		ID_PAZIENTE = s.ID_PAZIENTE,
		ID_REPARTO = s.ID_REPARTO,
		TS_RICOVERO = s.TS_RICOVERO,
		TS_DIMISSIONE = s.TS_DIMISSIONE,
		DURATA_DEGENZA_GIORNI = s.DURATA_DEGENZA_GIORNI,
		TIPO_RICOVERO = s.TIPO_RICOVERO,
		ESITO_DIMISSIONE = s.ESITO_DIMISSIONE
	WHEN NOT MATCHED THEN INSERT (
		ID_RICOVERO,
		ID_PAZIENTE,
		ID_REPARTO,
		TS_RICOVERO,
		TS_DIMISSIONE,
		DURATA_DEGENZA_GIORNI,
		TIPO_RICOVERO,
		ESITO_DIMISSIONE
	)
	VALUES (
		s.ID_RICOVERO,
		s.ID_PAZIENTE,
		s.ID_REPARTO,
		s.TS_RICOVERO,
		s.TS_DIMISSIONE,
		s.DURATA_DEGENZA_GIORNI,
		s.TIPO_RICOVERO,
		s.ESITO_DIMISSIONE
	);

	-- c) FACT_MISURAZIONI (ORA_GIORNO derivata)
	MERGE INTO HEALTHCARE_DW.ANALYTICS.FACT_MISURAZIONI t
	USING (
		SELECT
			ID_MISURAZIONE,
			ID_PAZIENTE,
			ID_DISPOSITIVO,
			DATA_MISURAZIONE AS TS_MISURAZIONE,
			EXTRACT(HOUR FROM DATA_MISURAZIONE) AS ORA_GIORNO,
			FREQUENZA_CARDIACA,
			SATURAZIONE_OSSIGENO,
			PRESSIONE_SISTOLICA,
			PRESSIONE_DIASTOLICA,
			TEMPERATURA_C,
			GLICEMIA_MG_DL
		FROM HEALTHCARE_DW.CURATED.PARAMETRI_VITALI
	) s
	ON t.ID_MISURAZIONE = s.ID_MISURAZIONE
	WHEN MATCHED THEN UPDATE SET
		ID_PAZIENTE = s.ID_PAZIENTE,
		ID_DISPOSITIVO = s.ID_DISPOSITIVO,
		TS_MISURAZIONE = s.TS_MISURAZIONE,
		ORA_GIORNO = s.ORA_GIORNO,
		FREQUENZA_CARDIACA = s.FREQUENZA_CARDIACA,
		SATURAZIONE_OSSIGENO = s.SATURAZIONE_OSSIGENO,
		PRESSIONE_SISTOLICA = s.PRESSIONE_SISTOLICA,
		PRESSIONE_DIASTOLICA = s.PRESSIONE_DIASTOLICA,
		TEMPERATURA_C = s.TEMPERATURA_C,
		GLICEMIA_MG_DL = s.GLICEMIA_MG_DL
	WHEN NOT MATCHED THEN INSERT (
		ID_MISURAZIONE,
		ID_PAZIENTE,
		ID_DISPOSITIVO,
		TS_MISURAZIONE,
		ORA_GIORNO,
		FREQUENZA_CARDIACA,
		SATURAZIONE_OSSIGENO,
		PRESSIONE_SISTOLICA,
		PRESSIONE_DIASTOLICA,
		TEMPERATURA_C,
		GLICEMIA_MG_DL
	)
	VALUES (
		s.ID_MISURAZIONE,
		s.ID_PAZIENTE,
		s.ID_DISPOSITIVO,
		s.TS_MISURAZIONE,
		s.ORA_GIORNO,
		s.FREQUENZA_CARDIACA,
		s.SATURAZIONE_OSSIGENO,
		s.PRESSIONE_SISTOLICA,
		s.PRESSIONE_DIASTOLICA,
		s.TEMPERATURA_C,
		s.GLICEMIA_MG_DL
	);

	RETURN 'OK';
$$;
```

// Screenshot suggerito: 09_sf_create_procedure_sp_publish_analytics.png

_Nota su `DIM_TEMPO`_: `DIM_TEMPO` è popolata come da Sezione 6; nelle analisi si usa `CAST(TS_* AS DATE)` o `DATE_TRUNC('DAY', TS_*)`.

== Orchestrazione e scheduling (HEALTHCARE_DW.PIPELINE)

L'orchestrazione è implementata con *TASK* in catena (`AFTER`) nello schema tecnico `HEALTHCARE_DW.PIPELINE`, con scheduling giornaliero alle 02:00 (Europe/Rome) sul task root.

#figure(
	```sql
USE ROLE SYSADMIN;
USE DATABASE HEALTHCARE_DW;

CREATE SCHEMA IF NOT EXISTS PIPELINE;
```,
	caption: "Creazione dello schema tecnico HEALTHCARE_DW.PIPELINE"
)

// Screenshot suggerito: 10_sf_create_schema_pipeline.png

=== Grant strutturali (staging + schema)

```sql
USE ROLE SECURITYADMIN;

-- Staging (RAW)
GRANT USAGE ON FILE FORMAT HEALTHCARE_DW.RAW.ff_parquet TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON STAGE HEALTHCARE_DW.RAW.stage_healthcare_raw TO ROLE ROLE_DATA_ENGINEER;

-- Schema PIPELINE (orchestrazione)
GRANT USAGE ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
GRANT CREATE PROCEDURE ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
GRANT CREATE TASK ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;

-- Accesso in sola lettura per audit/controlli
GRANT USAGE ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_COMPLIANCE_OFFICER;
```

*Task chain: procedure → task root schedulato → task downstream*

Le procedure sono richiamate dai task e sono definite con `EXECUTE AS OWNER`.
La sequenza di creazione è: procedure → task chain → grant runtime.

```sql
USE ROLE ROLE_DATA_ENGINEER;
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.PIPELINE;

CREATE OR REPLACE TASK task_load_raw
	WAREHOUSE = WH_INGEST
	SCHEDULE = 'USING CRON 0 2 * * * Europe/Rome'
AS
	CALL HEALTHCARE_DW.PIPELINE.sp_load_raw();

CREATE OR REPLACE TASK task_transform_curated
	WAREHOUSE = WH_OPERATIONS
	AFTER task_load_raw
AS
	CALL HEALTHCARE_DW.PIPELINE.sp_transform_curated();

CREATE OR REPLACE TASK task_publish_analytics
	WAREHOUSE = WH_ANALYTICS
	AFTER task_transform_curated
AS
	CALL HEALTHCARE_DW.PIPELINE.sp_publish_analytics();
```

// Screenshot suggerito: 11_sf_show_procedures_tasks_pipeline.png

=== Grant runtime (warehouse + execute + operate)

Questi grant rendono eseguibile la pipeline con `ROLE_DATA_ENGINEER` (warehouse, database/schema e controllo operativo dei task tramite `OPERATE`).
Il privilegio `OPERATE` governa l'operatività (resume/suspend/execute/monitor) senza concedere privilegi amministrativi più ampi.

```sql
USE ROLE SECURITYADMIN;

-- Warehouse
GRANT USAGE ON WAREHOUSE WH_INGEST TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_OPERATIONS TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_ANALYTICS TO ROLE ROLE_DATA_ENGINEER;

-- Database e layer
GRANT USAGE ON DATABASE HEALTHCARE_DW TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ENGINEER;

-- Execute procedure
GRANT EXECUTE ON PROCEDURE HEALTHCARE_DW.PIPELINE.sp_load_raw() TO ROLE ROLE_DATA_ENGINEER;
GRANT EXECUTE ON PROCEDURE HEALTHCARE_DW.PIPELINE.sp_transform_curated() TO ROLE ROLE_DATA_ENGINEER;
GRANT EXECUTE ON PROCEDURE HEALTHCARE_DW.PIPELINE.sp_publish_analytics() TO ROLE ROLE_DATA_ENGINEER;

-- Operatività task
GRANT OPERATE ON TASK HEALTHCARE_DW.PIPELINE.task_load_raw TO ROLE ROLE_DATA_ENGINEER;
GRANT OPERATE ON TASK HEALTHCARE_DW.PIPELINE.task_transform_curated TO ROLE ROLE_DATA_ENGINEER;
GRANT OPERATE ON TASK HEALTHCARE_DW.PIPELINE.task_publish_analytics TO ROLE ROLE_DATA_ENGINEER;
```

=== Ownership e delega operativa (EXECUTE AS OWNER)

- Le procedure e i task vengono creati con `ROLE_DATA_ENGINEER` (owner degli oggetti in `HEALTHCARE_DW.PIPELINE`).
- `EXECUTE AS OWNER` implica che l'esecuzione delle procedure usa i privilegi dell'owner della procedura.
- Il controllo operativo della catena (resume/suspend/execute/monitor) viene delegato esplicitamente via `GRANT OPERATE` sui task.

*Evidenza grant/ownership (screenshot-friendly)*

```sql
SHOW GRANTS ON PROCEDURE HEALTHCARE_DW.PIPELINE.sp_load_raw();
SHOW GRANTS ON TASK HEALTHCARE_DW.PIPELINE.task_load_raw;
```

// Screenshot suggerito: 12_sf_grant_execute_procedures.png
// Screenshot suggerito: 13_sf_grant_operate_tasks.png

*Attivazione della catena e run end-to-end controllato (evidenza)*

```sql
ALTER TASK HEALTHCARE_DW.PIPELINE.task_load_raw RESUME;
ALTER TASK HEALTHCARE_DW.PIPELINE.task_transform_curated RESUME;
ALTER TASK HEALTHCARE_DW.PIPELINE.task_publish_analytics RESUME;

EXECUTE TASK HEALTHCARE_DW.PIPELINE.task_load_raw;
```

// Screenshot suggerito: 14_sf_execute_task_root.png

== Controlli e monitoraggio (evidenze)

I controlli verificano riconciliazione per layer e integrità logica; il monitoraggio operativo usa la task history.

*Riconciliazione row counts (RAW → CURATED → ANALYTICS)*

```sql
SELECT 'RAW.PAZIENTI' AS table_name, COUNT(*) AS n FROM HEALTHCARE_DW.RAW.PAZIENTI
UNION ALL
SELECT 'CURATED.PAZIENTI', COUNT(*) FROM HEALTHCARE_DW.CURATED.PAZIENTI
UNION ALL
SELECT 'CURATED.RICOVERI', COUNT(*) FROM HEALTHCARE_DW.CURATED.RICOVERI
UNION ALL
SELECT 'ANALYTICS.FACT_RICOVERI', COUNT(*) FROM HEALTHCARE_DW.ANALYTICS.FACT_RICOVERI;
```

// Screenshot suggerito: 15_sf_rowcount_reconciliation.png

*Controllo orfani (coerenza logica in CURATED su ricoveri)*

```sql
SELECT COUNT(*) AS ricoveri_orfani
FROM HEALTHCARE_DW.CURATED.RICOVERI r
LEFT JOIN HEALTHCARE_DW.CURATED.PAZIENTI p
	ON r.ID_PAZIENTE = p.ID_PAZIENTE
WHERE p.ID_PAZIENTE IS NULL;
```

// Screenshot suggerito: 16_sf_orphans_check_curated_ricoveri.png

*Controllo duplicati (chiave naturale in CURATED)*

```sql
SELECT ID_RICOVERO, COUNT(*) AS n
FROM HEALTHCARE_DW.CURATED.RICOVERI
GROUP BY ID_RICOVERO
HAVING COUNT(*) > 1;
```

// Screenshot suggerito: 17_sf_duplicates_check_curated_ricoveri.png

*Monitoraggio esecuzione pipeline (task history)*

```sql
SELECT *
FROM TABLE(
	HEALTHCARE_DW.INFORMATION_SCHEMA.TASK_HISTORY(
		TASK_NAME => 'HEALTHCARE_DW.PIPELINE.TASK_LOAD_RAW',
		RESULT_LIMIT => 50
	)
)
ORDER BY SCHEDULED_TIME DESC;
```

// Screenshot suggerito: 18_sf_task_history.png

```sql
SELECT *
FROM TABLE(HEALTHCARE_DW.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 50))
WHERE NAME IN (
	'HEALTHCARE_DW.PIPELINE.TASK_LOAD_RAW',
	'HEALTHCARE_DW.PIPELINE.TASK_TRANSFORM_CURATED',
	'HEALTHCARE_DW.PIPELINE.TASK_PUBLISH_ANALYTICS'
)
ORDER BY SCHEDULED_TIME DESC;
```

// Screenshot suggerito: 18b_sf_task_history_chain_filtered.png

=== Gestione operativa errori e rerun controllato

- Se `task_load_raw` fallisce, i task downstream (`task_transform_curated`, `task_publish_analytics`) *non* vengono eseguiti, perché la catena è vincolata da `AFTER`.
- Il rerun controllato avviene rieseguendo il *root task* con `EXECUTE TASK` (la catena riparte dal punto iniziale previsto).
- `TASK_HISTORY` espone stato e diagnostica operativa (`STATE`, `ERROR_MESSAGE`, `QUERY_ID`, tempi), utili per troubleshooting e per evidenze a screenshot.

```sql
SELECT
	NAME,
	STATE,
	ERROR_MESSAGE,
	QUERY_ID,
	SCHEDULED_TIME,
	COMPLETED_TIME
FROM TABLE(
	HEALTHCARE_DW.INFORMATION_SCHEMA.TASK_HISTORY(
		RESULT_LIMIT => 50
	)
)
WHERE NAME LIKE 'HEALTHCARE_DW.PIPELINE.%'
ORDER BY SCHEDULED_TIME DESC;
```

// Screenshot suggerito: 18c_sf_task_history_operational_view.png

La gestione errori è deterministica:

- *Ingestion fail-fast*: `ON_ERROR = 'ABORT_STATEMENT'` interrompe l'esecuzione su incompatibilità schema/file.
- *Quarantena*: record non conformi confluiscono in `*_QUARANTENA` via `INSERT` e non contaminano `CURATED`.
- *Re-run controllato*: `COPY_HISTORY` governa la tracciabilità in `RAW`; i `MERGE` garantiscono idempotenza in `CURATED` e `ANALYTICS`.
