= Architettura logica su Snowflake

== Visione d'insieme

In questa sezione documento la configurazione dell'ambiente Snowflake che ho realizzato. Utilizzando un account trial di 30 giorni, ho implementato un'architettura che separa nettamente le risorse di calcolo da quelle di storage, sfruttando la natura nativa cloud della piattaforma.

L'obiettivo è passare da un disegno logico a un'implementazione fisica verificabile, preparando il terreno per l'ingestione e la trasformazione dei dati.

== Creazione del database principale

Come primo passo, ho creato il container logico di alto livello per ospitare tutti gli oggetti del progetto. Ho scelto il nome `HEALTHCARE_DW` per identificare chiaramente l'ambito di dominio.

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

// Screenshot suggerito: 01_sf_database_creato.png

== Implementazione del Data Layering (Schemi)

Per riflettere la stratificazione dei dati definita durante l'analisi, ho suddiviso il database in tre schemi distinti. Questa organizzazione logica mi permette di governare il ciclo di vita del dato:

1.  *RAW*: Punto di atterraggio dei dati grezzi provenienti da S3.
2.  *CURATED*: Livello intermedio per pulizia e normalizzazione.
3.  *ANALYTICS*: Livello finale ottimizzato per le query di analisi.

Ho eseguito il seguente script DDL:

#figure(
  ```sql
CREATE SCHEMA HEALTHCARE_DW.RAW;
CREATE SCHEMA HEALTHCARE_DW.CURATED;
CREATE SCHEMA HEALTHCARE_DW.ANALYTICS;
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

// Screenshot suggerito: 02_sf_schemas_creati.png

== Configurazione delle risorse di calcolo (Virtual Warehouse)

Per garantire prestazioni ottimali e isolamento dei carichi di lavoro, ho adottato una strategia multi-warehouse. In Snowflake, separare le risorse di calcolo impedisce che operazioni diverse (come un caricamento massivo dati) competano per le stesse risorse di una query di analisi, rallentandola.

Ho quindi definito tre warehouse distinti, ciascuno dimensionato in base al compito specifico.

=== Warehouse per Ingestion

Il primo warehouse è dedicato alle operazioni di caricamento dati (ETL/ELT). Ho scelto una taglia *X-Small* per contenere i costi durante le fasi di copia e trasformazione iniziale.

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

Una volta creato, ho verificato le proprietà del warehouse:

#figure(
  ```sql
SHOW WAREHOUSES LIKE 'WH_INGEST';
```,
  caption: "Verifica Warehouse di Ingestione"
)

// Screenshot suggerito: 03_sf_warehouse_creato.png

=== Warehouse per Operazioni (Consultazione)

Per le query frequenti a bassa latenza e l'interrogazione puntuale dei dati, ho creato un warehouse separato. Questo garantisce che le attività di consultazione non vengano bloccate dai processi di caricamento.

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

// Screenshot suggerito: 04_sf_wh_operations.png

=== Warehouse per Analisi (Analytics)

Infine, ho configurato un warehouse dedicato ai carichi di lavoro analitici complessi (Query OLAP, calcolo KPI, aggregazioni). Per questo carico ho selezionato una taglia *Small* (doppia potenza rispetto a X-Small), necessaria per gestire query più onerose su volumi di dati aggregati.

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

// Screenshot suggerito: 05_sf_wh_analytics.png

== Predisposizione per l'integrazione con lo Storage

In questa fase ho preparato l'architettura interna per accogliere i dati esterni. La creazione degli oggetti specifici per l'integrazione con lo storage esterno (S3) e le relative definizioni di *Storage Integration* e *File Format* verranno trattate nel dettaglio nella fase di ingestione, una volta configurati i permessi lato cloud provider.

== Riepilogo assetto architetturale

Al termine di queste operazioni, l'ambiente Snowflake è configurato come segue:

- *Database*: `HEALTHCARE_DW`
- *Struttura Schemi*:
  - `RAW` $->$ Ingestione da Stage
  - `CURATED` $->$ Trasformazioni
  - `ANALYTICS` $->$ Consumo dati
- *Compute*:
  - `WH_INGEST` (X-Small) $->$ Caricamento dati
  - `WH_OPERATIONS` (X-Small) $->$ Query operative
  - `WH_ANALYTICS` (Small) $->$ Analisi avanzata

Questa configurazione costituisce le fondamenta per l'implementazione del modello dati fisico che descriverò nella prossima sezione.
