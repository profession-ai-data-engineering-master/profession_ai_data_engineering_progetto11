= Generazione dei dati sintetici

== Motivazione e approccio

In questa sezione descrivo il processo che ho seguito per la generazione dei dati. Non potendo utilizzare informazioni cliniche reali per evidenti vincoli di privacy e conformità GDPR, ho deciso di produrre un dataset sintetico che rispecchiasse fedelmente le caratteristiche di un sistema ospedaliero reale.

Il mio obiettivo principale è stato quello di creare una base dati verosimile, utile per validare il modello e le pipeline di ingestione su Snowflake, senza esporre informazioni sensibili.

== Strumenti utilizzati: SDV

Per la generazione dei dati ho utilizzato la libreria Python *SDV (Synthetic Data Vault)*. Ho scelto questo strumento perché permette di modellare relazioni complesse tra tabelle e di mantenere la coerenza statistica dei dati generati.

Ho sviluppato uno script dedicato che definisce le regole di generazione per le varie entità (pazienti, visite, diagnosi). Il codice sorgente completo dello script è disponibile nel repository GitHub separato:
#link("https://github.com/fedevita/healthdata-synthetic-generator.git")[
  vedi healthdata-synthetic-generator
]

== Caratteristiche del dataset

Ho strutturato il dataset in modo da coprire i principali domini informativi richiesti:
- Dati anagrafici dei pazienti.
- Storia clinica e ricoveri.
- Dettagli su esami e diagnosi.

Questa varietà mi permette di simulare scenari di analisi realistici nelle fasi successive del progetto.

== Ingestione e staging su Amazon S3

Una volta generati i file (in formato CSV o JSON), ho configurato un bucket su *Amazon S3* per fungere da area di staging.
Ho scelto questa architettura per simulare un ambiente di produzione in cui i dati vengono depositati in una "Landing Zone" prima di essere caricati nel Data Warehouse. Da qui, i dati saranno pronti per essere ingeriti in Snowflake.
