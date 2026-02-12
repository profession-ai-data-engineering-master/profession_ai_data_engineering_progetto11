= Architettura logica su Snowflake

== Visione d'insieme

In questa sezione documento la configurazione dell'ambiente Snowflake che ho realizzato. 
Utilizzando un account trial di 30 giorni, ho implementato un'architettura che separa nettamente le risorse di calcolo da quelle di storage, 
sfruttando la natura nativa cloud della piattaforma.

L'obiettivo è passare da un disegno logico a un'implementazione fisica verificabile, preparando il terreno per l'ingestione e la trasformazione dei dati.

== Creazione del database principale

Come primo passo, ho creato il container logico di alto livello per ospitare tutti gli oggetti del progetto. 
Ho scelto il nome `HEALTHCARE_DW` per identificare chiaramente l'ambito di dominio.

#figure(
  ```sql
CREATE DATABASE HEALTHCARE_DW;
```,
  caption: "Creazione del database HEALTHCARE_DW"
)

Subito dopo l'esecuzione, ho verificato la corretta creazione del database interrogando i metadati di sistema:

#figure(
  ```sql
SHOW DATABASES LIKE 'HEALTHCARE_DW';
```,
  caption: "Verifica creazione database"
)

Per assicurarmi che tutti i comandi successivi vengano eseguiti nel contesto corretto, ho impostato il database attivo:

#figure(
  ```sql
USE DATABASE HEALTHCARE_DW;
```,
  caption: "Impostazione del database attivo"
)

== Implementazione del Data Layering (Schemi)

Per riflettere la stratificazione dei dati definita durante l'analisi, ho suddiviso il database in quattro schemi distinti. Questa organizzazione logica mi permette di governare il ciclo di vita del dato:

1.  *RAW*: Punto di atterraggio dei dati grezzi provenienti da S3.
2.  *CURATED*: Livello intermedio per pulizia e normalizzazione.
3.  *ANALYTICS*: Livello finale ottimizzato per le query di analisi.
4.  *PIPELINE*: schema tecnico dedicato all'orchestrazione che ospiterà le procedure stored e i task chain, separando la logica di controllo dai dati.

Ho eseguito il seguente script DDL:

#figure(
  ```sql
CREATE SCHEMA HEALTHCARE_DW.RAW;
CREATE SCHEMA HEALTHCARE_DW.CURATED;
CREATE SCHEMA HEALTHCARE_DW.ANALYTICS;
CREATE SCHEMA HEALTHCARE_DW.PIPELINE;
```,
  caption: "Creazione degli schemi (Data Layering)"
)

Per confermare la struttura, ho listato gli schemi presenti nel database:

#figure(
  ```sql
SHOW SCHEMAS IN DATABASE HEALTHCARE_DW;
```,
  caption: "Verifica creazione schemi"
)

// Screenshot suggerito: sf_ui_database_structure.png (Vista grafica Database -> Schemas)

== Configurazione delle risorse di calcolo (Virtual Warehouse)

Per garantire prestazioni ottimali e isolamento dei carichi di lavoro, ho adottato una strategia multi-warehouse. 
In Snowflake, separare le risorse di calcolo impedisce che operazioni diverse (come un caricamento massivo dati) competano per le stesse risorse di una query di analisi, rallentandola. 
Ogni warehouse opera in modo indipendente, permettendo di scalare verticalmente o orizzontalmente specifici carichi di lavoro senza impattare le prestazioni delle altre attività.

Ho quindi definito tre warehouse distinti, ciascuno dimensionato in base al compito specifico.

=== Warehouse per Ingestion

Il primo warehouse è dedicato alle operazioni di caricamento dati (ETL/ELT). Ho scelto una taglia *XSMALL* per contenere i costi durante le fasi di copia e trasformazione iniziale.

#figure(
  ```sql
CREATE WAREHOUSE WH_INGEST
  WITH WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
```,
  caption: "Definizione Warehouse per Ingestione"
)

=== Warehouse per Operazioni (Consultazione)

Per le query frequenti a bassa latenza e l'interrogazione puntuale dei dati, ho creato un warehouse separato. 
Questo garantisce che le attività di consultazione non vengano bloccate dai processi di caricamento.

#figure(
  ```sql
CREATE WAREHOUSE WH_OPERATIONS
  WITH WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
```,
  caption: "Definizione Warehouse per Operazioni"
)

=== Warehouse per Analisi (Analytics)

Infine, ho configurato un warehouse dedicato ai carichi di lavoro analitici complessi (query analitiche su dataset aggregati e calcolo di KPI complessi). 
Per questo carico ho selezionato una taglia *Small* (doppia potenza rispetto a XSMALL), necessaria per gestire query più onerose su volumi di dati aggregati.

#figure(
  ```sql
CREATE WAREHOUSE WH_ANALYTICS
  WITH WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
```,
  caption: "Definizione Warehouse per Analytics"
)

== Riepilogo assetto architetturale

// Screenshot suggerito: sf_ui_warehouse_list.png

Al termine di queste operazioni, l'ambiente Snowflake è configurato come segue:

- *Database*: `HEALTHCARE_DW`
- *Struttura Schemi*:
  - `RAW` $->$ Ingestione da Stage
  - `CURATED` $->$ Trasformazioni
  - `ANALYTICS` $->$ Consumo dati
  - `PIPELINE` $->$ Orchestrazione
- *Compute*:
  - `WH_INGEST` (XSMALL) $->$ Caricamento dati
  - `WH_OPERATIONS` (XSMALL) $->$ Query operative
  - `WH_ANALYTICS` (Small) $->$ Analisi avanzata

Questa configurazione costituisce le fondamenta per l'implementazione del modello dati fisico che descriverò nella prossima sezione.

