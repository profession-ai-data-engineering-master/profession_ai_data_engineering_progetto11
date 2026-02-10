= Progettazione del modello dati

== Il cuore del progetto

In questa sezione presento il modello dati che ho progettato, che rappresenta il deliverable centrale dell'intero lavoro. La definizione dello schema e delle tabelle è il risultato della sintesi tra l'analisi dei requisiti e le best practice di modellazione per il Data Warehousing.

Ho puntato a creare un modello che fosse al tempo stesso espressivo, capace cioè di rappresentare fedelmente la realtà clinica, e performante per le interrogazioni analitiche.

== Entità principali

Ho identificato e modellato le seguenti macro-aree informative:

- *Pazienti*: L'entità centrale, contenente i dati anagrafici e demografici, gestita con particolare attenzione alla privacy.
- *Visite e Ricoveri*: Le tabelle transazionali che registrano gli eventi clinici, le date di ammissione e dimissione, e i reparti coinvolti.
- *Diagnosi e Procedure*: Le entità che dettagliano gli aspetti medici, collegando i pazienti agli esiti clinici e ai trattamenti ricevuti.

== Relazioni concettuali

Ho definito le relazioni tra queste entità per garantire l'integrità referenziale e permettere navigazioni fluide tra i dati.
Ad esempio, ho strutturato il legame tra Paziente e Visita per ricostruire l'intera storia clinica di un individuo, e il legame tra Visita e Diagnosi per analizzare l'incidenza delle patologie per reparto.

In questa fase preliminare presento il livello concettuale; nelle specifiche tecniche successive si entrerà nel dettaglio dei tipi di dato e dei vincoli fisici implementati su Snowflake.
