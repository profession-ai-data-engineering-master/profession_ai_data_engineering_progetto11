= Modellazione logica dei dati sintetici

== Principi di modellazione

Ho definito lo schema logico per garantire coerenza referenziale tra le entita' provenienti dalle diverse sorgenti, mantenendo una chiara separazione dei domini applicativi. Ho basato la progettazione su chiavi surrogate e relazioni esplicite che consentono una generazione sintetica controllata e un'agevole ingestione in Snowflake.

== Tabelle principali per sorgente

=== EHR

- *patients*
- *admissions*
- *diagnoses*

=== ERP

- *wards*
- *staff*
- *staff_assignments*

=== IoT

- *devices*
- *vital_signs*

== Chiavi primarie

- *patients.patient_id*
- *admissions.admission_id*
- *diagnoses.diagnosis_id*
- *wards.ward_id*
- *staff.staff_id*
- *staff_assignments.assignment_id*
- *devices.device_id*
- *vital_signs.measurement_id*

== Chiavi esterne e relazioni

- *admissions.patient_id* -> *patients.patient_id* (N:1)
- *admissions.ward_id* -> *wards.ward_id* (N:1)
- *diagnoses.admission_id* -> *admissions.admission_id* (N:1)
- *staff_assignments.staff_id* -> *staff.staff_id* (N:1)
- *staff_assignments.ward_id* -> *wards.ward_id* (N:1)
- *devices.ward_id* -> *wards.ward_id* (N:1)
- *vital_signs.patient_id* -> *patients.patient_id* (N:1)
- *vital_signs.device_id* -> *devices.device_id* (N:1)

== Cardinalita'

- Ho definito che un paziente puo' avere molti ricoveri (1:N).
- Ho definito che un ricovero puo' avere molte diagnosi (1:N).
- Ho definito che un reparto puo' avere molte assegnazioni operative (1:N).
- Ho definito che un reparto puo' avere molti dispositivi (1:N).
- Ho definito che un paziente puo' avere molte misurazioni vitali (1:N).

== Motivazione delle scelte di modellazione

Ho separato le entita' per riflettere la struttura reale dei sistemi ospedalieri e per preservare la tracciabilita' degli eventi clinici. Ho progettato le relazioni per assicurare l'integrita' dei collegamenti tra sorgenti e per supportare analisi trasversali, come la correlazione tra risorse operative e outcome clinici.

== Enfasi sulla coerenza referenziale

Ho vincolato la generazione sintetica a relazioni esplicite tra chiavi primarie e chiavi esterne, evitando la produzione di record orfani o inconsistenze tra tabelle. Questa impostazione mi permette di simulare in modo credibile i processi informativi e di ridurre le attivita' di data quality in fase di ingestione.
