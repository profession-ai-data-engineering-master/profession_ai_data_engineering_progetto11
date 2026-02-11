= Piano di azione per la realizzazione del progetto

== Introduzione al piano di azione

In questo piano di azione definisco la strategia adottata per la realizzazione del progetto, seguendo un approccio strutturato e incrementale tipico delle pipeline di Data Engineering.

Il percorso copre l’intero ciclo di vita del dato: dalla generazione sintetica alla progettazione architetturale, dalla modellazione alla definizione delle politiche di sicurezza, fino al popolamento dei layer analitici e alla validazione finale.

Ogni fase descritta di seguito corrisponde a una specifica sezione del documento, mantenendo coerenza tra sviluppo tecnico e organizzazione espositiva.

== Fase 1: Generazione preliminare di dati sintetici

Il punto di partenza del progetto è la disponibilità del dato. In assenza di dati reali, e per garantire il rispetto delle normative sulla privacy e del GDPR, genero un dataset sintetico verosimile.

I dati sono prodotti tramite uno script basato sulla libreria *SDV (Synthetic Data Vault)*, che assicura coerenza statistica e relazionale. Lo script di generazione è disponibile nel repository GitHub dedicato:

#link("https://github.com/fedevita/healthdata-synthetic-generator.git")[
  vedi healthdata-synthetic-generator
]

Operativamente, i dati vengono caricati su *Amazon S3*, configurato come area di staging (*landing zone*), simulando l'acquisizione da una sorgente esterna eterogenea.

== Fase 2: Analisi dei requisiti e definizione del perimetro

Con i dati disponibili e gli obiettivi di business definiti, mi concentro sull’analisi dei requisiti funzionali e non funzionali.

Traduco le esigenze di consolidamento, analisi KPI, interrogazioni temporali e governance in specifiche tecniche di modellazione, identificando entità, relazioni e vincoli principali.

== Fase 3: Disegno architetturale su Snowflake

Definito il perimetro, progetto l'architettura su Snowflake organizzando database e schemi secondo una stratificazione logica a livelli:

- RAW (staging)
- CURATED (standardizzazione)
- ANALYTICS (data mart)

Questa struttura garantisce separazione dei livelli di qualità del dato e prepara il terreno per sicurezza e trasformazioni controllate.

== Fase 4: Progettazione del modello dati

Questa fase rappresenta il cuore del progetto. Definisco il modello fisico su Snowflake, progettando le tabelle dei layer RAW, CURATED e ANALYTICS.

Vengono esplicitati:

- grain delle tabelle dei fatti,
- chiavi primarie e surrogate,
- relazioni tra dimensioni e fatti,
- logiche dimensionali e temporali.

Il modello è concepito per supportare sia accesso operativo puntuale sia analisi aggregata tramite KPI.

== Fase 5: Definizione della sicurezza e governance (RBAC)

Una volta definito il modello dati, strutturo la strategia di sicurezza secondo un approccio RBAC (Role-Based Access Control).

Applico il principio del minimo privilegio, definendo ruoli e permessi coerenti con:

- la separazione tra layer RAW, CURATED e ANALYTICS,
- la protezione dei dati sensibili,
- la distinzione tra utenti tecnici e utenti analitici.

La sicurezza viene quindi integrata come componente strutturale dell’architettura.

== Fase 6: Implementazione del caricamento dati e delle pipeline di trasformazione

Con modello e sicurezza definiti, implemento il flusso di popolamento dei dati.

Il processo prevede:

- ingestione nel layer RAW,
- trasformazione e standardizzazione nel layer CURATED,
- costruzione delle tabelle dimensionali e dei fatti nel layer ANALYTICS.

In questa fase vengono applicate logiche di pulizia, gestione delle chiavi, normalizzazione e controlli di qualità del dato, garantendo coerenza tra modello teorico e dati effettivamente caricati.

== Fase 7: Validazione analitica e query dimostrative

A seguito del popolamento completo del modello, verifico la sua efficacia tramite interrogazioni SQL sul layer ANALYTICS.

Dimostro che:

- le tabelle dei fatti supportano correttamente le aggregazioni richieste,
- le dimensioni consentono analisi temporali e per reparto,
- la struttura permette drill-down su singolo evento.

La validazione conferma che l’intero flusso produce insight coerenti con i requisiti iniziali.

== Fase 8: Finalizzazione e consegna

Concludo il progetto verificando la coerenza complessiva tra requisiti, architettura, modello, sicurezza, pipeline e validazione.

Rifinisco la documentazione e preparo il materiale finale per la consegna in formato `.zip`.