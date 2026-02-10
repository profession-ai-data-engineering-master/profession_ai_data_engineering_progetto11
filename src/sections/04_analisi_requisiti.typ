= Analisi dei requisiti e definizione del perimetro

== Scopo dell'analisi

L'obiettivo di questa fase è tradurre le necessità operative di HealthDataPro in specifiche tecniche chiare, colmando il divario tra la generazione dei dati (descritta nella sezione precedente) e la loro strutturazione nel Data Warehouse. Questa analisi costituisce la base logica che ha guidato le scelte architetturali e di modellazione descritte nei capitoli successivi.

Prima di definire nel dettaglio l'architettura e il modello dati, ho voluto chiarire *cosa* il sistema deve garantire, affinché l'implementazione su Snowflake non sia solo un repository passivo, ma un motore analitico performante, sicuro e aderente ai processi ospedalieri.

== Requisiti funzionali e impatto architetturale

Ho identificato i requisiti di business prioritari e ne ho mappato l'impatto diretto sulla strategia di gestione dei dati. La seguente tabella sintetizza il ragionamento che lega i bisogni operativi alle decisioni strutturali:

#table(
  columns: (30%, 35%, 35%),
  inset: 10pt,
  align: horizon,
  [*Requisito Funzionale*], [*Impatto sui Dati*], [*Implicazione Progettuale*],

  [Consolidamento domini eterogenei],
  [I dati provengono da flussi distinti (EHR, ERP, IoT) con strutture e frequenze di aggiornamento diverse.],
  [Adozione di un'architettura a livelli (Layering) per normalizzare i dati grezzi in uno schema unificato e coerente.],

  [Analisi delle performance ospedaliere],
  [Necessità di calcolare metriche complesse (es. durata ricoveri, efficienza staff) incrociando domini diversi.],
  [Progettazione di un modello dimensionale ottimizzato per la lettura e le aggregazioni analitiche (OLAP).],

  [Accesso rapido ai dati],
  [La consultazione operativa richiede tempi di risposta immediati per supportare le decisioni cliniche.],
  [Definizione di strutture di accesso ottimizzate per garantire bassa latenza nelle interrogazioni puntuali.],

  [Sicurezza e segregazione dei dati],
  [Coesistenza di dati amministrativi aperti e dati clinici altamente sensibili (PII/PHI) nello stesso ambiente.],
  [Predisposizione di un modello di controllo accessi (RBAC) granulare e segregazione logica degli schemi.]
)

== Requisiti non funzionali

Oltre alle funzionalità esplicite, ho definito una serie di criteri di qualità che il sistema deve soddisfare per garantire robustezza operativa:

- *Performance analitiche*: Il sistema deve garantire tempi di risposta rapidi anche su query che aggregano grandi volumi di dati storici.
- *Scalabilità*: L'architettura deve poter gestire la crescita del volume dei dati simulati senza richiedere modifiche strutturali al modello dati.
- *Integrità e qualità*: Deve essere garantita la coerenza referenziale tra i domini (es. legame paziente-diagnosi), gestendo eventuali anomalie del dato sintetico.
- *Auditabilità*: Le operazioni sui dati devono avvenire in un contesto controllato che permetta, ove necessario, di ricostruire la storia delle modifiche.

== Perimetro del progetto

Per garantire un'esecuzione efficace e focalizzata sugli obiettivi di Data Engineering, ho delimitato chiaramente i confini del mio intervento.

*In Scope (Oggetto del progetto):*
- Definizione dell'architettura Snowflake (Database, Schemi, Warehouse) e strategia di deployment.
- Progettazione delle pipeline di ingestione e trasformazione dati da S3 a Snowflake.
- Definizione del modello dati logico e fisico per i livelli Raw, Curated e Analytics.
- Progettazione del modello di sicurezza e della gerarchia dei ruoli (RBAC).
- Identificazione delle strategie di ottimizzazione per le query analitiche.

*Out of Scope (Escluso dal progetto):*
- Sviluppo di dashboard di Business Intelligence o interfacce frontend.
- Implementazione di pipeline di streaming in tempo reale (es. Kafka/Kinesis).
- Gestione dell'infrastruttura di rete o hardware sottostante.
- Integrazione con sistemi ospedalieri fisici reali (i dati sono generati sinteticamente).

== Assunzioni e vincoli

L'analisi e la successiva implementazione si basano sulle seguenti premesse operative:
1. *Sorgente Dati*: Si assume che i dati siano già disponibili nel bucket S3 in formato Parquet, organizzati per dominio (EHR/ERP/IoT) come descritto nelle sezioni precedenti.
2. *Approccio ELT*: Viene privilegiato un approccio Extract-Load-Transform, sfruttando la potenza di calcolo di Snowflake per le trasformazioni post-caricamento.
3. *Immutabilità del Raw*: I dati grezzi non vengono modificati in loco, ma storicizzati per garantire la riproducibilità delle pipeline.

