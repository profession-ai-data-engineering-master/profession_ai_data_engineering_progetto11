= Architettura logica su Snowflake

== Visione d'insieme

In questa sezione descrivo l'architettura che ho progettato all'interno di Snowflake. Ho scelto di organizzare l'ambiente in modo logico e gerarchico, sfruttando le capacità della piattaforma di separare il calcolo dallo storage e di gestire carichi di lavoro concorrenti.

L'architettura non è un semplice contenitore di tabelle, ma una struttura pensata per governare il ciclo di vita del dato, dall'ingestione grezza fino alla sua trasformazione in informazione di valore.

== Organizzazione di database e schemi

Ho strutturato l'environment Snowflake suddividendo i dati in diversi schemi logici, ognuno con una precisa responsabilità. Questa separazione mi permette di mantenere ordine e pulizia, facilitando la manutenzione e l'evoluzione futura del sistema.

== Stratificazione dei dati (Data Layering)

Ho adottato concettualmente una divisione a livelli (Layering) per la gestione dei flussi dati:

- *Raw Layer*: In questo livello atterrano i dati "grezzi", così come arrivano dall'area di staging su S3. Qui non applico trasformazioni significative, preservando la fedeltà alla fonte originale.
- *Curated Layer*: È il livello intermedio dove avvengono la pulizia, la normalizzazione e l'integrazione. Qui risolvo eventuali incongruenze e strutturo i dati per l'utilizzo operativo.
- *Analytics Layer*: Questo è il livello finale, ottimizzato per le performance di lettura. Qui risiedono le viste e le tabelle aggregate pronte per essere consumate dagli strumenti di BI e dai report direzionali.

Questa stratificazione mi garantisce che ogni stadio elaborativo sia isolato e controllabile.
