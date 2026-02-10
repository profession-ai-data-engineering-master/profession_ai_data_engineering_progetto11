= Analisi dei requisiti e definizione del perimetro

== Obiettivi dell'analisi

In questa sezione espongo l'analisi che ho condotto sui requisiti iniziali del progetto. Prima di procedere con l'implementazione tecnica, ho esaminato le necessità di business espresse da HealthDataPro per tradurle in specifiche tecniche concrete.

Il mio focus è stato quello di definire un perimetro chiaro per il sistema, assicurandomi che ogni scelta architetturale rispondesse a una precisa esigenza funzionale.

== Traduzione dei requisiti funzionali

Ho mappato i requisiti principali in questo modo:
- *Consolidamento*: Ho previsto strutture dati in grado di accogliere informazioni da fonti eterogenee, normalizzandole in un unico schema.
- *Accesso Real-time*: Ho progettato il modello per supportare query efficienti, minimizzando le latenze di accesso per il personale medico e amministrativo.
- *Analisi Avanzata*: Ho strutturato le tabelle per facilitare le aggregazioni necessarie alla reportistica sui KPI ospedalieri (es. durata ricoveri, efficienza reparti).

== Definizione del perimetro del sistema

Sulla base di questa analisi, ho circoscritto l'ambito del progetto alla creazione del backend dati su Snowflake.
Non mi sono occupato della realizzazione di interfacce utente o dashboard frontend, concentrando i miei sforzi sulla solidità, scalabilità e sicurezza del modello dati sottostante, che costituisce le fondamenta dell'intera soluzione.
