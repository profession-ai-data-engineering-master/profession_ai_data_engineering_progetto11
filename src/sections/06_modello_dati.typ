= Progettazione del modello dati

== Obiettivo del modello e criteri di progettazione

In questa sezione definisco il modello dati fisico su Snowflake, traducendo i requisiti analitici in strutture tabellari concrete. L'architettura segue il pattern a tre livelli (RAW, CURATED, ANALYTICS) già predisposto infrastrutturalmente nella Sezione 5.

Prima di entrare nel dettaglio dei layer, esplicito i due principi cardine che hanno guidato questa progettazione:

1.  *Natural Keys First*: Poiché il dataset sintetico generato (cfr. Sezione 3) fornisce già identificativi univoci stabili (es. `id_paziente`, `id_ricovero`, `id_misurazione`), ho scelto di mantenere queste chiavi naturali come Primary Key lungo tutta la pipeline, evitando l'introduzione di chiavi surrogate (autoincrementali) non necessarie in questa fase.
2.  *Vincoli Informational su Snowflake*: In Snowflake, i vincoli di Primary Key e Foreign Key sono utilizzati principalmente per documentazione e per ottimizzare il query planner, ma *non* vengono imposti rigidamente (enforced) durante il caricamento. La garanzia della qualità dati è quindi demandata alle procedure ELT di trasformazione e validazione, non al motore del database.

== Definizione del grain

Ho definito esplicitamente la granularità (*grain*) delle tabelle principali per assicurare la correttezza delle aggregazioni KPI:

- *Ricoveri*: 1 riga per ogni episodio di ricovero.
- *Parametri Vitali*: 1 riga per ogni evento di rilevazione (misurazione) registrato da un dispositivo.
- *Diagnosi*: 1 riga per ogni diagnosi specifica associata a un ricovero.

Questo grain granulare è essenziale per permettere il drill-down dal livello aggregato (es. reparto) al singolo evento clinico.

== Layer RAW – Tabelle di atterraggio (Mirror)

Il layer `RAW` funge da area di staging. Le tabelle qui definite rispecchiano la struttura del dizionario dati e sono compatibili con i Parquet generati presenti nel Data Lake su S3. Non applico trasformazioni né vincoli di integrità in questa fase: l'obiettivo è garantire un atterraggio veloce e sicuro del dato grezzo.

Tutti i tipi di dato sono stati mappati dal dizionario dati ai tipi nativi di Snowflake (`VARCHAR`, `DATE`, `TIMESTAMP_NTZ`, `NUMBER`, `FLOAT`).

```sql
USE DATABASE HEALTHCARE_DW;
USE SCHEMA HEALTHCARE_DW.RAW;
```

=== RAW – Dominio ERP (Enterprise Resource Planning)

_DDL RAW: tabelle del dominio ERP_

  ```sql
  -- 1. Reparti
  CREATE OR REPLACE TABLE REPARTI (
      ID_REPARTO VARCHAR,
      NOME_REPARTO VARCHAR,
      SPECIALITA VARCHAR
  ) COMMENT = 'Mirror raw dati reparti (ERP)';

  -- 2. Personale
  CREATE OR REPLACE TABLE PERSONALE (
      ID_STAFF VARCHAR,
      NOME VARCHAR,
      COGNOME VARCHAR,
      RUOLO VARCHAR,
      REPARTO VARCHAR,
      TIPO_IMPIEGO VARCHAR,
      EMAIL VARCHAR,
      TELEFONO VARCHAR,
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
  -- 6. Pazienti
  CREATE OR REPLACE TABLE PAZIENTI (
      ID_PAZIENTE VARCHAR,
      CODICE_FISCALE VARCHAR,
      NOME VARCHAR,
      COGNOME VARCHAR,
      SESSO VARCHAR,
      DATA_NASCITA DATE,
      STATO_CIVILE VARCHAR,
      LINGUA_PRIMARIA VARCHAR,
      GRUPPO_SANGUIGNO VARCHAR,
      CITTA VARCHAR,
      INDIRIZZO VARCHAR,
      CAP VARCHAR,
      PAESE VARCHAR,
      EMAIL VARCHAR,
      TELEFONO VARCHAR,
      COMPAGNIA_ASSICURATIVA VARCHAR,
      PIANO_ASSICURATIVO VARCHAR,
      ID_ASSICURAZIONE VARCHAR,
      CONTATTO_EMERGENZA_NOME VARCHAR,
      CONTATTO_EMERGENZA_TELEFONO VARCHAR,
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

La strategia adottata per la creazione delle tabelle prevede di ereditare la struttura dal layer RAW (`LIKE RAW...`) per massimizzare la coerenza, aggiungendo poi esplicitamente le chiavi primarie e esterne. I vincoli di business (es. coerenza date) sono documentati nel modello ma applicati logicamente durante le pipeline di trasformazione.

Ribadisco inoltre che in Snowflake i vincoli `PRIMARY KEY` e `FOREIGN KEY` sono *informational*: li uso per rendere esplicite le relazioni e migliorare la leggibilità del modello, non come meccanismo di enforcement a runtime.
L'integrità viene garantita dall'ordine di caricamento e dalle validazioni ELT; eventuali record duplicati o con riferimenti orfani vengono isolati (quarantena) o scartati *prima* dell'inserimento nel layer `CURATED`.

=== CURATED – Tabelle Anagrafiche e Strutturali (ERP Key)

_DDL CURATED: Anagrafiche e ERP_

  ```sql
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

_Nota Operativa_: Eventuali record che violano questi vincoli (es. riferimenti orfani o duplicati) verranno intercettati e scartati o messi in quarantena dalle logiche della pipeline ELT prima dell'inserimento in questo schema.

== Layer ANALYTICS – Modello dimensionale

Il livello `ANALYTICS` è modellato secondo i principi dello *Star Schema* per facilitare l'analisi tramite strumenti di BI.

Per mantenere il modello snello e coerente con i dati sintetici, ho utilizzato le *Business Key* originali come chiavi primarie delle dimensioni, evitando di rigenerare chiavi surrogate autoincrementali che avrebbero introdotto complessità non necessaria in questo scenario.

*Schema progettato:*
- *Dimensioni (DIM)*: `DIM_PAZIENTE`, `DIM_REPARTO`, `DIM_DISPOSITIVO`, `DIM_TEMPO`.
- *Fatti (FACT)*: `FACT_RICOVERI` (eventi clinici), `FACT_MISURAZIONI` (eventi IoT).
- *Bridge*: La tabella `DIAGNOSI` viene trattata come una tabella ponte (`BRIDGE_DIAGNOSI`) che lega diagnosi multiple al singolo ricovero. La considero un evento dipendente dal ricovero (1:N) e non una dimensione autonoma perché non è un attributo descrittivo stabile; così mantengo lo schema snello e coerente col dataset sintetico.

Per evitare conversioni implicite tra `DATE` e `TIMESTAMP_NTZ`, nelle tabelle dei fatti mantengo la precisione temporale completa (timestamp) anche nel layer `ANALYTICS`.
`DIM_TEMPO` rimane una tabella di supporto a granularità *giorno* (calendario) e non viene referenziata con FK dirette dalle colonne timestamp delle fact.
Anche in questo layer le PK/FK sono vincoli informational (non enforced) e l'integrità è garantita da validazioni ELT.

=== ANALYTICS – Dimensioni

_DDL ANALYTICS: Definizione delle Dimensioni_

  ```sql
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
      DATA_NASCITA DATE,
      CITTA VARCHAR,
      GRUPPO_SANGUIGNO VARCHAR,
      PIANO_ASSICURATIVO VARCHAR
  );
  ```

_Nota operativa_: popolerò `DIM_TEMPO` come tabella calendario (una riga per giorno) tramite script SQL/worksheet Snowflake o un generatore di date.
La estenderò almeno al range temporale coperto dal dataset, includendo eventuali margini (es. qualche mese prima/dopo) per evitare buchi nelle analisi.

=== ANALYTICS – Tabelle dei Fatti e Bridge

_DDL ANALYTICS: Fact Tables e Bridge_

  ```sql
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

Per collegarmi a `DIM_TEMPO` nelle analisi *senza perdere precisione temporale nello storage*, effettuo il join a livello di query usando `DATE_TRUNC('DAY', ...)` oppure il cast a `DATE`.

_Esempio: join a DIM_TEMPO in query (senza FK e senza cast impliciti nel modello fisico)_

  ```sql
  SELECT fr.ID_REPARTO, dt.ANNO, dt.MESE, COUNT(*) AS N_RICOVERI
  FROM FACT_RICOVERI fr
  JOIN DIM_TEMPO dt
    ON CAST(fr.TS_RICOVERO AS DATE) = dt.DATA
  GROUP BY fr.ID_REPARTO, dt.ANNO, dt.MESE;
  ```

== Mappatura sorgenti → RAW → CURATED → ANALYTICS

Riepilogo finale del flusso dati dai file sorgente fino al modello analitico.

#figure(
  {
    set text(size: 7pt)
    table(
      columns: (auto, auto, auto, auto),
      inset: 10pt,
      align: horizon,
      [*Sorgente Parquet*], [*RAW*], [*CURATED*], [*ANALYTICS*],
      
      [pazienti], [RAW.PAZIENTI], [CURATED.PAZIENTI], [DIM_PAZIENTE],
      [reparti], [RAW.REPARTI], [CURATED.REPARTI], [DIM_REPARTO],
      [dispositivi], [RAW.DISPOSITIVI], [CURATED.DISPOSITIVI], [DIM_DISPOSITIVO],
      [ricoveri], [RAW.RICOVERI], [CURATED.RICOVERI], [FACT_RICOVERI],
      [parametri_vitali], [RAW.PARAMETRI_VITALI], [CURATED.PARAMETRI_VITALI], [FACT_MISURAZIONI],
      [diagnosi], [RAW.DIAGNOSI], [CURATED.DIAGNOSI], [BRIDGE_DIAGNOSI],
      [personale], [RAW.PERSONALE], [CURATED.PERSONALE], [- (audit/analisi organizzativa)],
      [assegnazioni], [RAW.ASSEGNAZIONI], [CURATED.ASSEGNAZIONI], [- (audit/analisi organizzativa)]
    )
  },
  caption: [Lineage del dato: dai Raw Files al Data Mart]
)

== Conclusioni

In questa sezione ho definito l'architettura informativa su Snowflake, ora allineata e coerente con il dizionario dati della Sezione 3.
In particolare, ho mantenuto le chiavi naturali come PK lungo i layer e ho preservato la precisione temporale nelle fact (`TIMESTAMP_NTZ`), evitando conversioni implicite a `DATE`.
`DIM_TEMPO` resta disponibile come calendario giornaliero per le analisi, agganciabile in query tramite `CAST(... AS DATE)` o `DATE_TRUNC('DAY', ...)`.
