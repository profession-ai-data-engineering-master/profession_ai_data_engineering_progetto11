= Piano di azione per la realizzazione del progetto

== Introduzione al piano di azione

In questo piano di azione definisco la strategia che ho adottato per la realizzazione del progetto, seguendo un approccio strutturato e incrementale tipico delle pipeline di Data Engineering. Ho organizzato l'attività in fasi sequenziali che guidano l'intero ciclo di vita del dato, dalla sua genesi fino alla messa in sicurezza e alla consegna.

Per garantire la massima chiarezza espositiva e progettuale, ho strutturato il report in modo modulare: ogni fase che descrivo di seguito corrisponde a una specifica sezione del documento, guidando il lettore attraverso l'evoluzione del progetto.

== Fase 1: Generazione preliminare di dati sintetici

Punto di partenza del progetto è la disponibilità del dato. In assenza di dati reali, e per garantire il rigoroso rispetto delle normative sulla privacy e del GDPR, come prima attività ho generato un dataset sintetico verosimile. Questa fase preliminare mi ha permesso di definire e validare le caratteristiche del dominio clinico prima ancora di atterrare su Snowflake.

Ho prodotto i dati utilizzando uno script basato sulla libreria *SDV (Synthetic Data Vault)*, che assicura la coerenza statistica e relazionale delle informazioni. Lo script di generazione è disponibile in un repository GitHub dedicato: 
#link("https://github.com/fedevita/healthdata-synthetic-generator.git")[
  vedi healthdata-synthetic-generator
]

Operativamente, carico i dati generati su uno storage ad oggetti *Amazon S3*, configurato come area di *staging* o *landing zone*. Con questa scelta simulo realisticamente l'acquisizione da una sorgente esterna eterogenea. I dettagli di questo processo sono descritti nella sezione dedicata del report.

== Fase 2: Analisi dei requisiti e definizione del perimetro

Con i dati disponibili (seppur sintetici) e gli obiettivi di business chiari, nella seconda fase mi concentro sull'analisi puntuale dei requisiti del progetto. In questo step, traduco le necessità di consolidamento, accesso real-time, analisi avanzata e conformità in specifiche tecniche di modellazione.

Attraverso l'analisi identifico le entità di business e le loro relazioni, ponendo le basi per le scelte architetturali successive. Approfondisco questa fase logica in una sezione autonoma del documento.

== Fase 3: Disegno architetturale su Snowflake

Una volta definito il perimetro, procedo alla progettazione dell'architettura su Snowflake. In questa fase definisco l'organizzazione logica del database e degli schemi, implementando concettualmente una stratificazione dei dati (ad esempio livelli *Raw*, *Curated* e *Analytics*) per governare l'evoluzione dell'informazione grezza verso insight affidabili.

Ho pensato l'architettura per supportare sia l'ingestione efficiente che l'applicazione delle politiche di sicurezza. Le scelte architetturali delineano il "contenitore" in cui vivrà il modello dati e sono documentate in una specifica sezione del report.

== Fase 4: Progettazione del modello dati

Questa è la fase centrale del progetto, in cui realizzo il *deliverable principale*: lo schema delle tabelle su Snowflake. Partendo dall'analisi dei requisiti e dalla struttura dei dati sintetici generati, disegno un modello dati robusto e scalabile.

Ho progettato il modello per supportare dualmente l'accesso operativo (consultazione puntuale della storia clinica) e l'analisi aggregata (KPI ospedalieri). Definisco nel dettaglio le principali entità cliniche, le chiavi e le relazioni. Tratto la progettazione completa dello schema nella sezione dedicata al modello dati.

== Fase 5: Sicurezza e conformità (RBAC)

Parallelamente alla modellazione delle entità, implemento la strategia di sicurezza, intrinsecamente legata alla struttura dei dati. In questa fase definisco come proteggere le informazioni sensibili segregando l'accesso tramite un modello *RBAC (Role-Based Access Control)*.

Applicando il principio del minimo privilegio, stabilisco le regole che governano chi può vedere cosa, sfruttando le funzionalità native di Snowflake per la compliance GDPR (come il data masking concettuale). Espongo dettagliatamente le politiche di sicurezza e governance nella relativa sezione del report.

== Fase 6: Finalizzazione e consegna

Concludo il percorso con la rifinitura del modello dati e il consolidamento dell'intera documentazione progettuale. In questa fase finale verifico la coerenza tra le sezioni e la completezza rispetto ai requisiti iniziali, preparando il materiale finale per la consegna in formato `.zip`. Questa attività chiude il ciclo di lavoro descritto nel piano di azione.

