= Progettazione del modello dati

== Obiettivo del modello e criteri di progettazione

In questa sezione definisco il modello dati fisico su Snowflake, traducendo i requisiti analitici in strutture tabellari concrete. 
L'architettura segue il pattern a livelli (RAW, CURATED, ANALYTICS) già predisposto.

== Layer RAW – Tabelle di atterraggio (Mirror)

Il layer `RAW` funge da area di staging. Le tabelle qui definite rispecchiano la struttura del dizionario dati e sono compatibili con i Parquet 
generati presenti nel Data Lake su S3. Non applico trasformazioni né vincoli di integrità in questa fase: l'obiettivo è garantire un atterraggio veloce e sicuro del dato grezzo.

Tutti i tipi di dato sono stati mappati dal dizionario dati ai tipi nativi di Snowflake (`VARCHAR`, `DATE`, `TIMESTAMP_NTZ`, `NUMBER`, `FLOAT`).

=== RAW – Dominio ERP (Enterprise Resource Planning)

_DDL RAW: tabelle del dominio ERP_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.RAW;

  -- 1. Reparti
  CREATE OR REPLACE TABLE REPARTI (
      ID_REPARTO VARCHAR,
      NOME_REPARTO VARCHAR,
      SPECIALITA VARCHAR
  ) COMMENT = 'Mirror raw dati reparti (ERP)';

  -- 2. Personale
  CREATE OR REPLACE TABLE PERSONALE (
      ID_STAFF VARCHAR,
      NOME VARCHAR, --PII
      COGNOME VARCHAR, --PII
      RUOLO VARCHAR,
      REPARTO VARCHAR,
      TIPO_IMPIEGO VARCHAR,
      EMAIL VARCHAR, --PII
      TELEFONO VARCHAR, --PII
      ID_LICENZA VARCHAR,
      DATA_ASSUNZIONE DATE
  ) COMMENT = 'Mirror raw anagrafica personale (ERP)';

  -- 3. Assegnazioni
  CREATE OR REPLACE TABLE ASSEGNAZIONI (
      ID_ASSEGNAZIONE VARCHAR,
      ID_STAFF VARCHAR,
      ID_REPARTO VARCHAR,
      TURNO VARCHAR
  ) COMMENT = 'Mirror raw assegnazioni staff-reparto (ERP)';
  ```

=== RAW – Dominio IoT (Internet of Things)

_DDL RAW: tabelle del dominio IoT_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.RAW;

  -- 4. Dispositivi
  CREATE OR REPLACE TABLE DISPOSITIVI (
      ID_DISPOSITIVO VARCHAR,
      ID_REPARTO VARCHAR,
      TIPO_DISPOSITIVO VARCHAR,
      PRODUTTORE VARCHAR,
      MODELLO VARCHAR,
      NUMERO_SERIE VARCHAR,
      STATO VARCHAR,
      DATA_ACQUISTO DATE,
      DATA_ULTIMA_CALIBRAZIONE DATE
  ) COMMENT = 'Mirror raw dispositivi medici (IoT)';

  -- 5. Parametri Vitali
  CREATE OR REPLACE TABLE PARAMETRI_VITALI (
      ID_MISURAZIONE VARCHAR,
      ID_PAZIENTE VARCHAR,
      ID_DISPOSITIVO VARCHAR,
      DATA_MISURAZIONE TIMESTAMP_NTZ,
      FREQUENZA_CARDIACA NUMBER(3,0),
      SATURAZIONE_OSSIGENO NUMBER(3,0),
      PRESSIONE_SISTOLICA NUMBER(3,0),
      PRESSIONE_DIASTOLICA NUMBER(3,0),
      TEMPERATURA_C FLOAT,
      FREQUENZA_RESPIRATORIA NUMBER(3,0),
      GLICEMIA_MG_DL NUMBER(3,0)
  ) COMMENT = 'Mirror raw telemetria vitale (IoT)';
  ```

=== RAW – Dominio EHR (Electronic Health Record)

_DDL RAW: tabelle del dominio EHR_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.RAW;

  -- 6. Pazienti
  CREATE OR REPLACE TABLE PAZIENTI (
      ID_PAZIENTE VARCHAR,
      CODICE_FISCALE VARCHAR, --PII
      NOME VARCHAR, --PII
      COGNOME VARCHAR, --PII
      SESSO VARCHAR,
      DATA_NASCITA DATE, --PII
      STATO_CIVILE VARCHAR,
      LINGUA_PRIMARIA VARCHAR,
      GRUPPO_SANGUIGNO VARCHAR,
      CITTA VARCHAR, --PII
      INDIRIZZO VARCHAR, --PII
      CAP VARCHAR,
      PAESE VARCHAR,
      EMAIL VARCHAR, --PII
      TELEFONO VARCHAR, --PII
      COMPAGNIA_ASSICURATIVA VARCHAR,
      PIANO_ASSICURATIVO VARCHAR,
      ID_ASSICURAZIONE VARCHAR,
      CONTATTO_EMERGENZA_NOME VARCHAR, --PII
      CONTATTO_EMERGENZA_TELEFONO VARCHAR, --PII
      ALTEZZA_CM NUMBER(3,0),
      PESO_KG NUMBER(5,2)
  ) COMMENT = 'Mirror raw anagrafica pazienti (EHR)';

  -- 7. Ricoveri
  CREATE OR REPLACE TABLE RICOVERI (
      ID_RICOVERO VARCHAR,
      ID_PAZIENTE VARCHAR,
      ID_REPARTO VARCHAR,
      DATA_RICOVERO TIMESTAMP_NTZ,
      DATA_DIMISSIONE TIMESTAMP_NTZ,
      DURATA_DEGENZA_GIORNI NUMBER(3,0),
      TIPO_RICOVERO VARCHAR,
      PROVENIENZA_RICOVERO VARCHAR,
      ESITO_DIMISSIONE VARCHAR
  ) COMMENT = 'Mirror raw ricoveri ospedalieri (EHR)';

  -- 8. Diagnosi
  CREATE OR REPLACE TABLE DIAGNOSI (
      ID_DIAGNOSI VARCHAR,
      ID_RICOVERO VARCHAR,
      CODICE_ICD10 VARCHAR,
      GRAVITA VARCHAR
  ) COMMENT = 'Mirror raw diagnosi cliniche (EHR)';
  ```

_Nota_: rappresento `PESO_KG` con due decimali.

== Layer CURATED – Standardizzazione e qualità

Nel layer `CURATED`, consolido i dati applicando regole di standardizzazione e definendo vincoli relazionali.

La strategia adottata per la creazione delle tabelle prevede di ereditare la struttura dal layer RAW (`LIKE RAW...`) 
per massimizzare la coerenza, aggiungendo poi esplicitamente le chiavi primarie e esterne.

=== CURATED – Tabelle Anagrafiche e Strutturali (ERP Key)

_DDL CURATED: Anagrafiche e ERP_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.CURATED;

  -- Creazione e vincoli: Reparti e Personale
  CREATE OR REPLACE TABLE REPARTI LIKE HEALTHCARE_DW.RAW.REPARTI;
  ALTER TABLE REPARTI ADD PRIMARY KEY (ID_REPARTO);

  CREATE OR REPLACE TABLE PERSONALE LIKE HEALTHCARE_DW.RAW.PERSONALE;
  ALTER TABLE PERSONALE ADD PRIMARY KEY (ID_STAFF);
  
  -- Creazione e vincoli: Assegnazioni
  CREATE OR REPLACE TABLE ASSEGNAZIONI LIKE HEALTHCARE_DW.RAW.ASSEGNAZIONI;
  ALTER TABLE ASSEGNAZIONI ADD PRIMARY KEY (ID_ASSEGNAZIONE);
  ALTER TABLE ASSEGNAZIONI ADD CONSTRAINT FK_ASS_STAFF FOREIGN KEY (ID_STAFF) REFERENCES PERSONALE(ID_STAFF);
  ALTER TABLE ASSEGNAZIONI ADD CONSTRAINT FK_ASS_REP FOREIGN KEY (ID_REPARTO) REFERENCES REPARTI(ID_REPARTO);
  ```

=== CURATED – Dispositivi e Parametri Vitali (IoT)

_DDL CURATED: IoT e Telemetria_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.CURATED;

  -- Creazione e vincoli: Dispositivi
  CREATE OR REPLACE TABLE DISPOSITIVI LIKE HEALTHCARE_DW.RAW.DISPOSITIVI;
  ALTER TABLE DISPOSITIVI ADD PRIMARY KEY (ID_DISPOSITIVO);
  ALTER TABLE DISPOSITIVI ADD CONSTRAINT FK_DEV_REP FOREIGN KEY (ID_REPARTO) REFERENCES REPARTI(ID_REPARTO);

  -- Creazione e vincoli: Parametri Vitali
  CREATE OR REPLACE TABLE PARAMETRI_VITALI LIKE HEALTHCARE_DW.RAW.PARAMETRI_VITALI;
  ALTER TABLE PARAMETRI_VITALI ADD PRIMARY KEY (ID_MISURAZIONE);
  -- FK note: puntano a Pazienti (definito nel blocco EHR) e Dispositivi
  ALTER TABLE PARAMETRI_VITALI ADD CONSTRAINT FK_VIT_DEV FOREIGN KEY (ID_DISPOSITIVO) REFERENCES DISPOSITIVI(ID_DISPOSITIVO);
  -- (FK verso Pazienti viene applicata logicamente, ordine di creazione permettendo)
  ```

=== CURATED – Pazienti e Ricoveri (EHR)

_DDL CURATED: Pazienti e Cartella Clinica_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.CURATED;

  -- Creazione e vincoli: Pazienti
  CREATE OR REPLACE TABLE PAZIENTI LIKE HEALTHCARE_DW.RAW.PAZIENTI;
  ALTER TABLE PAZIENTI ADD PRIMARY KEY (ID_PAZIENTE);

  -- Creazione e vincoli: Ricoveri
  CREATE OR REPLACE TABLE RICOVERI LIKE HEALTHCARE_DW.RAW.RICOVERI;
  ALTER TABLE RICOVERI ADD PRIMARY KEY (ID_RICOVERO);
  ALTER TABLE RICOVERI ADD CONSTRAINT FK_RIC_PAZ FOREIGN KEY (ID_PAZIENTE) REFERENCES PAZIENTI(ID_PAZIENTE);
  ALTER TABLE RICOVERI ADD CONSTRAINT FK_RIC_REP FOREIGN KEY (ID_REPARTO) REFERENCES REPARTI(ID_REPARTO);

  -- Creazione e vincoli: Diagnosi
  CREATE OR REPLACE TABLE DIAGNOSI LIKE HEALTHCARE_DW.RAW.DIAGNOSI;
  ALTER TABLE DIAGNOSI ADD PRIMARY KEY (ID_DIAGNOSI);
  ALTER TABLE DIAGNOSI ADD CONSTRAINT FK_DIAG_RIC FOREIGN KEY (ID_RICOVERO) REFERENCES RICOVERI(ID_RICOVERO);
  
  -- completamento relazioni circolari o dipendenti
  ALTER TABLE PARAMETRI_VITALI ADD CONSTRAINT FK_VIT_PAZ FOREIGN KEY (ID_PAZIENTE) REFERENCES PAZIENTI(ID_PAZIENTE);
  ```

=== CURATED – Gestione Anomalie (Quarantena)

Le strutture `*_QUARANTENA` vengono predisposte per ospitare i record che falliscono le validazioni di qualità o l'integrità referenziale durante l'esecuzione delle pipeline.
Mantengono la struttura delle tabelle RAW per facilitare il debug e l'analisidelle anomalie (Data Quality) senza interrompere il flusso di caricamento.

_DDL CURATED: Tabelle di Quarantena_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.CURATED;

  -- 1. Quarantena Ricoveri (es. paziente non trovato o errori di formato)
  CREATE TABLE IF NOT EXISTS RICOVERI_QUARANTENA LIKE HEALTHCARE_DW.RAW.RICOVERI;

  -- 2. Quarantena Parametri Vitali (es. valori fuori soglia o device dismesso)
  CREATE TABLE IF NOT EXISTS PARAMETRI_VITALI_QUARANTENA LIKE HEALTHCARE_DW.RAW.PARAMETRI_VITALI;
  ```


== Layer ANALYTICS – Modello dimensionale

Il livello `ANALYTICS` è modellato secondo i principi dello *Star Schema* per facilitare l'analisi tramite strumenti di BI.

Per mantenere il modello snello e coerente con i dati sintetici, ho utilizzato le *Business Key* originali come chiavi primarie delle dimensioni, 
evitando di rigenerare chiavi surrogate autoincrementali che avrebbero introdotto complessità non necessaria in questo scenario.

*Schema progettato:*
- *Dimensioni (DIM)*: `DIM_PAZIENTE`, `DIM_REPARTO`, `DIM_DISPOSITIVO`.
- *Fatti (FACT)*: `FACT_RICOVERI` (eventi clinici), `FACT_MISURAZIONI` (eventi IoT).
- *Bridge*: La tabella `DIAGNOSI` viene trattata come una tabella ponte (`BRIDGE_DIAGNOSI`) che lega diagnosi multiple al singolo ricovero. 
La considero un evento dipendente dal ricovero (1:N) e non una dimensione autonoma perché non è un attributo descrittivo stabile; 
così mantengo lo schema snello e coerente col dataset sintetico.

=== ANALYTICS – Dimensioni

_DDL ANALYTICS: Definizione delle Dimensioni_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.ANALYTICS;

  -- Dimensione Tempo
  CREATE OR REPLACE TABLE DIM_TEMPO (
      DATA DATE PRIMARY KEY,
      ANNO INT,
      MESE INT,
      NOME_MESE VARCHAR,
      GIORNO_SETTIMANA VARCHAR,
      TRIMESTRE INT
  );

  -- Dimensione Reparto
  CREATE OR REPLACE TABLE DIM_REPARTO (
      ID_REPARTO VARCHAR PRIMARY KEY,
      NOME_REPARTO VARCHAR,
      SPECIALITA VARCHAR
  );

  -- Dimensione Dispositivo
  CREATE OR REPLACE TABLE DIM_DISPOSITIVO (
      ID_DISPOSITIVO VARCHAR PRIMARY KEY,
      TIPO_DISPOSITIVO VARCHAR,
      MODELLO VARCHAR,
      PRODUTTORE VARCHAR
  );
  
  -- Dimensione Paziente
  CREATE OR REPLACE TABLE DIM_PAZIENTE (
      ID_PAZIENTE VARCHAR PRIMARY KEY,
      SESSO VARCHAR,
      DATA_NASCITA DATE, --PII
      CITTA VARCHAR, --PII
      GRUPPO_SANGUIGNO VARCHAR,
      PIANO_ASSICURATIVO VARCHAR
  );
  ```

=== ANALYTICS – Tabelle dei Fatti e Bridge

_DDL ANALYTICS: Fact Tables e Bridge_

  ```sql
  USE DATABASE HEALTHCARE_DW;
  USE SCHEMA HEALTHCARE_DW.ANALYTICS;

  -- Fact Table: Ricoveri
  CREATE OR REPLACE TABLE FACT_RICOVERI (
      ID_RICOVERO VARCHAR PRIMARY KEY,
      -- FK verso Dimensioni (Business Keys)
      ID_PAZIENTE VARCHAR REFERENCES DIM_PAZIENTE(ID_PAZIENTE),
      ID_REPARTO VARCHAR REFERENCES DIM_REPARTO(ID_REPARTO),
      TS_RICOVERO TIMESTAMP_NTZ,
      TS_DIMISSIONE TIMESTAMP_NTZ,
      
      -- Metriche
      DURATA_DEGENZA_GIORNI NUMBER(3,0),
      TIPO_RICOVERO VARCHAR,
      ESITO_DIMISSIONE VARCHAR
  );

  -- Fact Table: Misurazioni (Wide)
  CREATE OR REPLACE TABLE FACT_MISURAZIONI (
      ID_MISURAZIONE VARCHAR PRIMARY KEY,
      -- FK verso Dimensioni
      ID_PAZIENTE VARCHAR REFERENCES DIM_PAZIENTE(ID_PAZIENTE),
      ID_DISPOSITIVO VARCHAR REFERENCES DIM_DISPOSITIVO(ID_DISPOSITIVO),
      TS_MISURAZIONE TIMESTAMP_NTZ,
      -- Campo derivato da TS_MISURAZIONE (solo per query veloci per fascia oraria)
      ORA_GIORNO NUMBER(2,0),
      
      -- Metriche
      FREQUENZA_CARDIACA NUMBER(3,0),
      SATURAZIONE_OSSIGENO NUMBER(3,0),
      PRESSIONE_SISTOLICA NUMBER(3,0),
      PRESSIONE_DIASTOLICA NUMBER(3,0),
      TEMPERATURA_C FLOAT,
      GLICEMIA_MG_DL NUMBER(3,0)
  );
  
  -- Bridge Table: Diagnosi (1:N su Ricoveri)
  CREATE OR REPLACE TABLE BRIDGE_DIAGNOSI (
      ID_DIAGNOSI VARCHAR PRIMARY KEY,
      ID_RICOVERO VARCHAR REFERENCES FACT_RICOVERI(ID_RICOVERO),
      CODICE_ICD10 VARCHAR,
      GRAVITA VARCHAR
  );
  ```

== Conclusioni

In questa sezione ho definito l'architettura informativa su Snowflake, ora allineata e coerente con il dizionario dati.

// Screenshot suggerito: sf_ui_database_structure_with_tables.png
#figure(
  image("../assets/sf_ui_database_structure_with_tables.png", width: 30%),
  caption: "Screenshot: vista UI degli schemi e delle tabelle nel database HEALTHCARE_DW"
)
