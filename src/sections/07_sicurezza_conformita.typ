= Sicurezza e conformità normativa

In continuità con la progettazione del modello dati, la sicurezza è stata definita come una *proprietà del ciclo di vita del dato* e non come un insieme di regole astratte.
La separazione `RAW → CURATED → ANALYTICS` non rappresenta solo una scelta di organizzazione logica, ma diventa la base per applicare controlli di accesso e protezioni diverse in funzione di:

- sensibilità del contenuto (presenza di PII e dati sanitari)
- scopo del layer (atterraggio, standardizzazione, consumo)
- responsabilità operative (ingestion/ELT vs analisi)

== 7.1 Principi di sicurezza applicati al modello

La strategia di sicurezza segue direttamente la stratificazione a tre layer definita nel data warehouse `HEALTHCARE_DW`.

- *Layer RAW (staging / mirror)*: contiene i dati così come arrivano dalle sorgenti, inclusa la componente più ricca di PII nella tabella `RAW.PAZIENTI` (es. `CODICE_FISCALE`, contatti, indirizzo, email, telefono). Per questo motivo l'accesso a `RAW` è ristretto e destinato esclusivamente a chi gestisce l'ingestione e le trasformazioni.

- *Layer CURATED (standardizzazione e qualità)*: rappresenta il punto in cui applico le regole di qualità e le relazioni (PK/FK *informational*, non enforced). Proprio perché l'integrità è demandata alla pipeline ELT, limito i privilegi di scrittura a ruoli tecnici: in questo modo riduco il rischio di scritture manuali non tracciate che potrebbero introdurre incoerenze rispetto alle validazioni (es. orfani o duplicati).

- *Layer ANALYTICS (consumo)*: ospita il modello dimensionale (`DIM_*`, `FACT_*`) progettato per BI. È il livello in cui operano gli utenti di business; di conseguenza, l'accesso per analisi avviene qui e non su `RAW`. Anche in `ANALYTICS` sono presenti attributi che possono costituire PII o quasi-identificatori nella `DIM_PAZIENTE` (es. `DATA_NASCITA`, `CITTA`), quindi il consumo viene protetto con *masking policy* applicate a colonne specifiche.

== 7.2 Strategia RBAC su Snowflake

Ho implementato il controllo accessi tramite *RBAC nativo Snowflake*, definendo ruoli coerenti con le responsabilità sul ciclo di vita del dato.
L'obiettivo è che le pipeline ELT operino con un ruolo tecnico dedicato e che gli utenti analitici lavorino esclusivamente sul layer di consumo.

Ruoli definiti:

- `ROLE_DATA_ENGINEER`: ingestione e trasformazioni (scrittura su `RAW`/`CURATED`, pubblicazione su `ANALYTICS`).
- `ROLE_DATA_ANALYST`: consultazione e analisi su `ANALYTICS` (e, dove necessario, `CURATED` in sola lettura).
- `ROLE_COMPLIANCE_OFFICER`: verifica e auditing; *visibilità completa ai fini di controllo* (lettura), inclusa la visibilità non mascherata degli attributi PII dove previsto dalle policy, senza privilegi di scrittura.

_DDL Snowflake: creazione ruoli_

	```sql
	USE ROLE SECURITYADMIN;

	CREATE ROLE IF NOT EXISTS ROLE_DATA_ENGINEER;
	CREATE ROLE IF NOT EXISTS ROLE_DATA_ANALYST;
	CREATE ROLE IF NOT EXISTS ROLE_COMPLIANCE_OFFICER;
	```

=== Gerarchia dei ruoli

Per semplificare la gestione e garantire che chi controlla abbia sempre almeno la stessa visibilità di chi analizza, ho stabilito una gerarchia esplicita.
Il `ROLE_COMPLIANCE_OFFICER` eredita il `ROLE_DATA_ANALYST`: questo assicura che qualsiasi oggetto esposto per l'analisi sia automaticamente visibile (e auditabile) dal Compliance Officer senza necessità di doppi privilegi.

	```sql
	USE ROLE SECURITYADMIN;

	-- Il Compliance Officer "è anche" un Data Analyst (vede ciò che vede l'analista)
	GRANT ROLE ROLE_DATA_ANALYST TO ROLE ROLE_COMPLIANCE_OFFICER;
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

Nel layer `CURATED` il `ROLE_DATA_ENGINEER` deve poter effettuare trasformazioni e pubblicazioni (tipicamente tramite `INSERT` e operazioni di upsert/merge). Il `ROLE_DATA_ANALYST` accede in sola lettura, quando necessario, per verifiche o analisi intermedie.

	```sql
	USE ROLE SECURITYADMIN;

	GRANT USAGE ON SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;
	GRANT USAGE ON SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ANALYST;

	-- Data Engineer: trasformazioni e caricamenti
	GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;
	GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ENGINEER;

	-- Analyst: sola lettura (ereditata anche da Compliance)
	GRANT SELECT ON ALL TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ANALYST;
	GRANT SELECT ON FUTURE TABLES IN SCHEMA HEALTHCARE_DW.CURATED TO ROLE ROLE_DATA_ANALYST;
	```

=== ANALYTICS

`ANALYTICS` è il layer di consumo: il `ROLE_DATA_ANALYST` lavora qui in sola lettura sul modello dimensionale (`DIM_*`, `FACT_*` come `DIM_PAZIENTE`, `FACT_RICOVERI`). Il `ROLE_COMPLIANCE_OFFICER` dispone di visibilità completa per controlli e verifiche.

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

== 7.4 Protezione dei dati sensibili (PII)

Nel modello dimensionale ho ridotto la quantità di attributi anagrafici esposti, ma `DIM_PAZIENTE` contiene comunque campi che possono consentire re-identificazione o profilazione, tra cui `CITTA` e `DATA_NASCITA`.
Per rendere la protezione *applicativa e verificabile*, utilizzo *Masking Policy* Snowflake applicate a colonne mirate, differenziando la visibilità in base al ruolo effettivo (`CURRENT_ROLE()`).

_Esempio: masking di `DIM_PAZIENTE.CITTA` con visibilità piena solo per Compliance (e ruolo tecnico)_

	```sql
	-- Usecase: creazione oggetto di policy (richiede privilegi globali o ACCOUNTADMIN)
	USE ROLE ACCOUNTADMIN;
	USE DATABASE HEALTHCARE_DW;
	USE SCHEMA HEALTHCARE_DW.ANALYTICS;

	CREATE OR REPLACE MASKING POLICY MP_DIM_PAZIENTE_CITTA AS (val STRING)
	RETURNS STRING ->
		CASE
			WHEN val IS NULL THEN NULL
			WHEN CURRENT_ROLE() IN ('ROLE_COMPLIANCE_OFFICER', 'ROLE_DATA_ENGINEER', 'ACCOUNTADMIN') THEN val
			ELSE '***'
		END;

	-- Applicazione della policy alla colonna
	ALTER TABLE DIM_PAZIENTE
		MODIFY COLUMN CITTA
		SET MASKING POLICY MP_DIM_PAZIENTE_CITTA;
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

== 7.6 Auditabilità e tracciamento accessi

Per rendere il controllo effettivo (e non solo dichiarativo), Snowflake mette a disposizione viste di audit a livello account interrogabili tramite lo schema `SNOWFLAKE.ACCOUNT_USAGE`.
In particolare, `QUERY_HISTORY` consente di ricostruire *chi* ha eseguito *quale query* e *quando*, mentre `ACCESS_HISTORY` consente di analizzare l'accesso effettivo agli oggetti/colonne, supportando la verifica degli accessi su dati sensibili.

	```sql
	-- Esempi di interrogazione delle viste di audit (account-level)
	SELECT QUERY_ID, USER_NAME, ROLE_NAME, WAREHOUSE_NAME, START_TIME
	FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
	ORDER BY START_TIME DESC;

	SELECT QUERY_ID, USER_NAME, ROLE_NAME, QUERY_START_TIME
	FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
	ORDER BY QUERY_START_TIME DESC;
	```

Questa auditabilità completa il modello RBAC e il masking: oltre a *prevenire* accessi non necessari (least privilege), consente di *monitorare* e *ricostruire* gli accessi in caso di verifiche interne o controlli di conformità.