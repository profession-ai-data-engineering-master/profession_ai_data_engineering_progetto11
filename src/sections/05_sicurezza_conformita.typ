= Sicurezza e conformità normativa

In continuità con la progettazione del modello dati, la sicurezza è stata definita come una *proprietà del ciclo di vita del dato* e non come un insieme di regole astratte.
La separazione `RAW → CURATED → ANALYTICS` non rappresenta solo una scelta di organizzazione logica, ma diventa la base per applicare controlli di accesso e protezioni diverse in funzione di:

- sensibilità del contenuto (presenza di PII e dati sanitari)
- scopo del layer (atterraggio, standardizzazione, consumo)
- responsabilità operative (ingestion/ELT vs analisi)

== 7.1 Principi di sicurezza applicati al modello

La strategia di sicurezza segue direttamente la stratificazione a tre layer definita nel data warehouse `HEALTHCARE_DW`.

- *Layer RAW (staging / mirror)*: contiene i dati così come arrivano dalle sorgenti, inclusa la componente più ricca di PII nella tabella 
`RAW.PAZIENTI` (es. `CODICE_FISCALE`, contatti, indirizzo, email, telefono). Per questo motivo l'accesso a `RAW` è ristretto e destinato 
esclusivamente a chi gestisce l'ingestione e le trasformazioni.

- *Layer CURATED (standardizzazione e qualità)*: rappresenta il punto in cui applico le regole di qualità e le relazioni (PK/FK *informational*, non enforced). 
Essendo che l'integrità è demandata alla pipeline ELT, limito i privilegi di scrittura a ruoli tecnici: 
in questo modo riduco il rischio di scritture manuali non tracciate che potrebbero introdurre incoerenze rispetto alle validazioni.

- *Layer ANALYTICS (consumo)*: ospita il modello dimensionale (`DIM_*`, `FACT_*`) progettato per BI. È il livello in cui operano gli utenti di business; 
di conseguenza, l'accesso per analisi avviene qui e non su `RAW`. Anche in `ANALYTICS` sono presenti attributi che possono costituire PII o quasi-identificatori 
nella `DIM_PAZIENTE` (es. `DATA_NASCITA`, `CITTA`), quindi il consumo viene protetto con *masking policy* applicate a colonne specifiche.

== 7.2 Strategia RBAC su Snowflake

Ho implementato il controllo accessi tramite *RBAC nativo Snowflake*, definendo ruoli coerenti con le responsabilità sul ciclo di vita del dato.
L'obiettivo è che le pipeline ELT operino con un ruolo tecnico dedicato e che gli utenti analitici lavorino esclusivamente sul layer di consumo.

Ruoli definiti:

- `ROLE_DATA_ENGINEER`: ingestione e trasformazioni (scrittura su `RAW`/`CURATED`, pubblicazione su `ANALYTICS`).
- `ROLE_DATA_ANALYST`: consultazione e analisi su `ANALYTICS` (e, dove necessario, `CURATED` in sola lettura).
- `ROLE_COMPLIANCE_OFFICER`: verifica e auditing; *visibilità completa ai fini di controllo* (lettura), 
inclusa la visibilità non mascherata degli attributi PII dove previsto dalle policy, senza privilegi di scrittura.

_DDL Snowflake: creazione ruoli_

	```sql
	USE ROLE SECURITYADMIN;

	CREATE ROLE IF NOT EXISTS ROLE_DATA_ENGINEER;
	CREATE ROLE IF NOT EXISTS ROLE_DATA_ANALYST;
	CREATE ROLE IF NOT EXISTS ROLE_COMPLIANCE_OFFICER;
	```

=== Gerarchia dei ruoli

Per semplificare la gestione e garantire che chi controlla abbia sempre almeno la stessa visibilità di chi analizza, ho stabilito una gerarchia esplicita.
Il `ROLE_COMPLIANCE_OFFICER` eredita il `ROLE_DATA_ANALYST`: questo assicura che qualsiasi oggetto esposto per l'analisi sia automaticamente visibile 
(e auditabile) dal Compliance Officer senza necessità di doppi privilegi.

	```sql
	USE ROLE SECURITYADMIN;

	-- Il Compliance Officer "è anche" un Data Analyst (vede ciò che vede l'analista)
	GRANT ROLE ROLE_DATA_ANALYST TO ROLE ROLE_COMPLIANCE_OFFICER;
	```

=== Assegnazione ruoli all'utente di lab

Per facilitare il testing e lo switch tra i diversi profili durante la validazione, assegno esplicitamente i tre ruoli definiti all'utente principale (`FEDEVITA1997`).

	```sql
	USE ROLE SECURITYADMIN;

	GRANT ROLE ROLE_DATA_ENGINEER TO USER FEDEVITA1997;
	GRANT ROLE ROLE_DATA_ANALYST TO USER FEDEVITA1997;
	GRANT ROLE ROLE_COMPLIANCE_OFFICER TO USER FEDEVITA1997;
	```

== 7.3 Assegnazione privilegi per layer

La matrice dei privilegi è costruita per schema, riflettendo la funzione di ciascun layer.
In tutti i casi, per poter operare su un oggetto Snowflake è necessario garantire `USAGE` sul database e sullo schema, oltre ai privilegi sulle tabelle.

=== Privilegi sui Virtual Warehouse (coerenza con Sezione 5)

In continuità con la strategia multi-warehouse (`WH_INGEST`, `WH_OPERATIONS`, `WH_ANALYTICS`), ho separato i privilegi di calcolo in modo che i ruoli utilizzino solo le risorse necessarie al proprio carico di lavoro.
Questo isolamento riduce la possibilità di interferenza tra ingestion/ELT e query analitiche e rende più governabile il consumo computazionale.

	```sql
	USE ROLE SECURITYADMIN;

	GRANT USAGE ON WAREHOUSE WH_INGEST TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON WAREHOUSE WH_ANALYTICS TO ROLE ROLE_DATA_ENGINEER;

	GRANT USAGE ON WAREHOUSE WH_ANALYTICS TO ROLE ROLE_DATA_ANALYST;
	-- Il ROLE_COMPLIANCE_OFFICER eredita USAGE su WH_ANALYTICS
	```

	_Prerequisiti comuni (accesso al database)_

	```sql
	USE ROLE SECURITYADMIN;

	GRANT USAGE ON DATABASE HEALTHCARE_DW TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON DATABASE HEALTHCARE_DW TO ROLE ROLE_DATA_ANALYST;
	-- Il ROLE_COMPLIANCE_OFFICER eredita USAGE sul Database
  ```

Nel layer `RAW` autorizzo la scrittura solo al ruolo tecnico; gli analisti non hanno accesso diretto alle tabelle mirror.

	```sql
	USE ROLE SECURITYADMIN;

	-- Accesso allo schema
	GRANT USAGE ON SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_COMPLIANCE_OFFICER;

	-- Privilegi sulle tabelle esistenti
	GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_DATA_ENGINEER;
	GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_COMPLIANCE_OFFICER;

	-- Coerenza nel tempo (oggetti futuri)
	GRANT SELECT, INSERT ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_DATA_ENGINEER;
	GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.RAW TO ROLE ROLE_COMPLIANCE_OFFICER;
	```

_Nota_: l'assenza di `GRANT USAGE` sullo schema `RAW` per `ROLE_DATA_ANALYST` impedisce l'esplorazione diretta dei dati grezzi (inclusa `RAW.PAZIENTI`).

=== CURATED

Nel layer `CURATED` il `ROLE_DATA_ENGINEER` deve poter effettuare trasformazioni e pubblicazioni (tipicamente tramite `INSERT` e operazioni di upsert/merge). Il `ROLE_DATA_ANALYST` accede in sola lettura per verifiche o analisi intermedie sulla qualità dei dati (inclusa la revisione delle anomalie nelle tabelle di quarantena).

	```sql
	USE ROLE SECURITYADMIN;

	GRANT USAGE ON SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ANALYST;

	-- Data Engineer: trasformazioni, caricamenti e gestione quarantena (R/W)
	GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;
	GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;

	-- Analyst: sola lettura per audit e data quality verify (ereditata anche da Compliance)
	GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ANALYST;
	GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ANALYST;
	```

=== ANALYTICS

`ANALYTICS` è il layer di consumo: il `ROLE_DATA_ANALYST` lavora qui in sola lettura sul modello dimensionale (`DIM_*`, `FACT_*` come `DIM_PAZIENTE`, `FACT_RICOVERI`). 
Il `ROLE_COMPLIANCE_OFFICER` dispone di visibilità completa per controlli e verifiche.

	```sql
	USE ROLE SECURITYADMIN;

	GRANT USAGE ON SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ANALYST;

	-- Analyst: consumo (SELECT) - Il Compliance Officer eredita questi privilegi
	GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ANALYST;
	GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ANALYST;

	-- Data Engineer: pubblicazione e manutenzione delle tabelle del data mart
	GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ENGINEER;
	GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.ANALYTICS TO ROLE ROLE_DATA_ENGINEER;
	```

=== PIPELINE

Lo schema `PIPELINE` ospita la logica di orchestrazione (Stored Procedures, Task, Streams). 
Trattandosi di uno schema puramente tecnico e operativo, l'accesso è strettamente riservato al Data Engineer, con visibilità di audit per il Compliance Officer.

	```sql
	USE ROLE SECURITYADMIN;

	GRANT USAGE ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_COMPLIANCE_OFFICER;

	-- Data Engineer: Creazione e gestione oggetti di orchestrazione
	GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE TASK, CREATE STREAM 
		ON SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;

	-- Privilegi operativi su oggetti di supporto (es. tabelle di log)
	GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
	GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;

	-- Privilegi per esecuzione e monitoraggio flussi
	GRANT OPERATE, MONITOR ON ALL TASKS IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
	GRANT OPERATE, MONITOR ON FUTURE TASKS IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
	GRANT CALL ON ALL PROCEDURES IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;
	GRANT CALL ON FUTURE PROCEDURES IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_DATA_ENGINEER;

	-- Compliance: sola lettura per audit
	GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_COMPLIANCE_OFFICER;
	GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.PIPELINE TO ROLE ROLE_COMPLIANCE_OFFICER;
	```

== 7.4 Protezione dei dati sensibili (PII)

L'analisi del modello dati conferma che gli identificatori diretti (`NOME`, `COGNOME`, `CODICE_FISCALE`, `EMAIL`, `TELEFONO`) sono stati strutturalmente esclusi dal layer `ANALYTICS` (Privacy by Design).
Tuttavia, la tabella `DIM_PAZIENTE` mantiene attributi *quasi-identificatori* che richiedono protezione specifica come identificato nel modello dati (`COMMENT 'PII'`):
- `CITTA`: rischio di profilazione geografica (granularità troppo fine).
- `DATA_NASCITA`: rischio di re-identificazione se incrociata con altre fonti.

Per mitigare questi rischi residui senza bloccare l'accesso al dato aggregato, utilizzo le *Masking Policy* dinamiche di Snowflake.
La policy viene applicata a livello di colonna e valuta il ruolo a runtime:
- *Analisti (`ROLE_DATA_ANALYST`)*: vedono il dato oscurato (`***` per stringhe, `1900-01-01` per date) in modo da proteggere la privacy individuale mantenendo la struttura tabellare.
- *Compliance & Tecnici*: vedono il dato in chiaro per validazione e auditing.

_DDL: Definizione e applicazione delle Masking Policy PII_

	```sql
	USE ROLE ACCOUNTADMIN;
	USE DATABASE HEALTHCARE_DW;
	USE SCHEMA HEALTHCARE_DW.ANALYTICS;

	-- 1. Policy Generica per stringhe sensibili (es. Città)
	CREATE OR REPLACE MASKING POLICY MP_PII_STRING AS (val STRING)
	RETURNS STRING ->
		CASE
			WHEN val IS NULL THEN NULL
			WHEN CURRENT_ROLE() IN ('ROLE_COMPLIANCE_OFFICER', 'ROLE_DATA_ENGINEER', 'ACCOUNTADMIN') THEN val
			ELSE '*** MASKED ***'
		END;

	-- 2. Policy per date di nascita (Quasi-Identifier)
	-- Si usa una data fittizia standard per mantenere il tipo di dato DATE valido ed evitare rotture nei tool di BI
	CREATE OR REPLACE MASKING POLICY MP_PII_DATE AS (val DATE)
	RETURNS DATE ->
		CASE
			WHEN val IS NULL THEN NULL
			WHEN CURRENT_ROLE() IN ('ROLE_COMPLIANCE_OFFICER', 'ROLE_DATA_ENGINEER', 'ACCOUNTADMIN') THEN val
			ELSE TO_DATE('1900-01-01') -- Sentinel value per utenti non privilegiati
		END;

	-- Applicazione alle colonne target in DIM_PAZIENTE (Uniche colonne PII esposte in Analytics)
	ALTER TABLE DIM_PAZIENTE MODIFY COLUMN CITTA 
		SET MASKING POLICY MP_PII_STRING;
		
	ALTER TABLE DIM_PAZIENTE MODIFY COLUMN DATA_NASCITA 
		SET MASKING POLICY MP_PII_DATE;
	```

Questo approccio è coerente con la separazione dei compiti:

- l'analista accede al layer di consumo (`ANALYTICS`) ma vede l'attributo mascherato
- il compliance officer mantiene visibilità per finalità di controllo
- il ruolo tecnico conserva la visibilità necessaria a debugging e riconciliazioni controllate

== 7.5 Principio del minimo privilegio e governance

L'intero impianto RBAC è costruito secondo *least privilege* e riflette lo stesso disaccoppiamento progettuale della Sezione 6:

- *separazione per layer*: ogni ruolo riceve privilegi in funzione dello scopo del layer (atterraggio, trasformazione, consumo)
- *scrittura limitata*: la scrittura è concessa ai soli ruoli tecnici, coerentemente con il fatto che PK/FK sono informational e l'integrità è garantita dalle validazioni ELT
- *consumo controllato*: l'accesso degli analisti è indirizzato verso `ANALYTICS` (star schema) e protetto da masking su attributi sensibili

In sintesi, il modello dati e il modello di sicurezza sono stati progettati congiuntamente: poiché in Snowflake i vincoli PK/FK sono *informational* e l'integrità referenziale è garantita dalla pipeline ELT (ordine di caricamento e validazioni), la scrittura manuale viene limitata ai soli ruoli tecnici. L'esposizione verso gli utenti di business avviene invece sul solo layer `ANALYTICS`, dove il dato è già normalizzato per il consumo e gli attributi sensibili della `DIM_PAZIENTE` sono protetti con masking policy.
