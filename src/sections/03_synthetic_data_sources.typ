= Sorgenti dati eterogenee

== Introduzione

Ho impostato il sistema informativo sanitario simulato su sorgenti distinte, ciascuna con propri processi applicativi, modelli informativi e livelli di strutturazione. Ho mantenuto la separazione in sorgenti autonome per riflettere l'organizzazione reale dei sistemi ospedalieri e per garantire la tracciabilita' delle dipendenze relazionali.

== Sistema di Cartelle Cliniche Elettroniche (EHR)

=== Contesto applicativo

Ho definito la sorgente EHR come nucleo clinico del sistema, con i dati generati durante il percorso di cura del paziente.

=== Tipologia dei dati e grado di strutturazione

- Ho modellato anagrafiche pazienti e attributi demografici in forma altamente strutturata.
- Ho tracciato eventi di ricovero e dimissione con timestamp e reparto di riferimento.
- Ho codificato le diagnosi secondo standard clinici.

=== Valore informativo

Con la sorgente EHR ho abilitato analisi cliniche longitudinali e la correlazione tra esiti e percorsi terapeutici con indicatori di processo.

=== Motivazione della separazione

Ho separato il sistema EHR perche' segue policy di gestione e ciclo di vita differenti rispetto ai sistemi amministrativi e tecnici; questa scelta mi consente governance e auditing mirati.

=== Dipendenze relazionali

- Ho definito i ricoveri con riferimento a pazienti e reparti.
- Ho vincolato le diagnosi ai ricoveri e, indirettamente, ai pazienti.

== Sistema ERP Ospedaliero

=== Contesto applicativo

Ho definito la sorgente ERP per governare le risorse organizzative dell'ospedale, inclusa la struttura dei reparti e il personale sanitario.

=== Tipologia dei dati e grado di strutturazione

- Ho modellato i reparti con attributi organizzativi e codice di costo.
- Ho descritto il personale medico con ruolo e specializzazione.
- Ho strutturato le assegnazioni operative per collegare personale e reparti.

=== Valore informativo

Con la sorgente ERP ho reso possibile la ricostruzione della capacita' operativa e dell'allocazione delle risorse, aspetti essenziali per analisi di efficienza.

=== Motivazione della separazione

Ho mantenuto separati i processi amministrativi perche' sono governati da sistemi e responsabilita' differenti rispetto al dominio clinico, con tempi di aggiornamento e policy di accesso specifici.

=== Dipendenze relazionali

- Ho definito le assegnazioni operative con riferimento a personale e reparti.
- Ho previsto i reparti come riferimento condiviso con la sorgente EHR.

== Sensori IoT Sanitari

=== Contesto applicativo

Ho definito la sorgente IoT per raccogliere misurazioni continue provenienti da dispositivi di monitoraggio clinico, integrati nei percorsi di cura.

=== Tipologia dei dati e grado di strutturazione

- Ho modellato parametri vitali con frequenza elevata e timestamp ad alta granularita'.
- Ho descritto i dispositivi di monitoraggio con metadati tecnici e stato operativo.

=== Valore informativo

Con le misurazioni IoT ho abilitato analisi near real-time e modelli predittivi su eventi critici.

=== Motivazione della separazione

Ho mantenuto separata la sorgente IoT perche' genera grandi volumi di dati semi-strutturati e richiede pipeline di acquisizione e storage diverse rispetto a quelle transazionali.

=== Dipendenze relazionali

- Ho vincolato i parametri vitali a pazienti e dispositivi.
- Ho associato i dispositivi a reparti o a specifici percorsi di ricovero.
